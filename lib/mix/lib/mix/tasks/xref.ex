defmodule Mix.Tasks.Xref do
  use Mix.Task

  import Mix.Compilers.Elixir,
    only: [read_manifest: 2, source: 0, source: 1, source: 2, module: 1]

  @shortdoc "Tracks references between modules"
  @recursive true
  @manifest "compile.elixir"

  @moduledoc """
  Tracks references between modules.

  This task is automatically reenabled, so you can perform multiple
  cross reference checks in the same Mix invocation.

  ## Xref modes

  The `xref` task expects a mode as first argument:

      mix xref MODE

  All available modes are discussed below.

  ### callers MODULE

  Prints all callers of the given `MODULE`. Examples:

      mix xref callers MyMod

  ### graph

  Prints a file dependency graph where an edge from `A` to `B` indicates
  that `A` (source) depends on `B` (sink).

      mix xref graph --format stats

  The following options are accepted:

    * `--exclude` - paths to exclude

    * `--label` - only shows relationships with the given label
      The labels are "compile", "struct" and "runtime"

    * `--only-nodes` - only shows the node names (no edges)

    * `--source` - displays all files that the given source file
      references (directly or indirectly)

    * `--sink` - displays all files that reference the given file
      (directly or indirectly)

    * `--format` - can be set to one of:

      * `pretty` - prints the graph to the terminal using Unicode characters.
        Each prints each file followed by the files it depends on. This is the
        default except on Windows;

      * `plain` - the same as pretty except ASCII characters are used instead of
        Unicode characters. This is the default on Windows;

      * `stats` - prints general statistics about the graph;

      * `dot` - produces a DOT graph description in `xref_graph.dot` in the
        current directory. Warning: this will override any previously generated file

  The `--source` and `--sink` options are particularly useful when trying to understand
  how the modules in a particular file interact with the whole system. You can combine
  those options with `--label` and `--only-nodes` to get all files that exhibit a certain
  property, for example:

      # To get all files that depend on lib/foo.ex
      mix xref graph --sink lib/foo.ex --only-nodes

      # To get all files that depend on lib/foo.ex at compile time
      mix xref graph --label compile --sink lib/foo.ex --only-nodes

      # To show general statistics about the graph
      mix xref graph --format stats

      # To limit statistics only to certain labels
      mix xref graph --format stats --label compile

  ## Shared options

  Those options are shared across all modes:

    * `--include-siblings` - includes dependencies that have `:in_umbrella` set
      to true in the current project in the reports. This can be used to find
      callers or to analyze graphs between projects

    * `--no-compile` - does not compile even if files require compilation

    * `--no-deps-check` - does not check dependencies

    * `--no-archives-check` - does not check archives

    * `--no-elixir-version-check` - does not check the Elixir version from mix.exs

  """

  @switches [
    abort_if_any: :boolean,
    archives_check: :boolean,
    compile: :boolean,
    deps_check: :boolean,
    elixir_version_check: :boolean,
    exclude: :keep,
    format: :string,
    include_siblings: :boolean,
    label: :string,
    only_nodes: :boolean,
    sink: :string,
    source: :string
  ]

  @impl true
  def run(args) do
    {opts, args} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("loadpaths")

    if Keyword.get(opts, :compile, true) do
      Mix.Task.run("compile")
    end

    Mix.Task.reenable("xref")

    case args do
      ["callers", callee] ->
        callers(callee, opts)

      ["graph"] ->
        graph(opts)

      ["deprecated"] ->
        Mix.shell().error("mix xref deprecated is deprecated and has no effect")

      ["unreachable"] ->
        Mix.shell().error("mix xref unreachable is deprecated and has no effect")

      _ ->
        Mix.raise("xref doesn't support this command. For more information run \"mix help xref\"")
    end
  end

  @doc """
  Deprecated API to retrieve all the function calls in the project.

  From Elixir v1.9, the xref pass is performed as the code is compiled,
  therefore no information is kept during compilation.
  """
  @deprecated "No alternative is available as xref is now done as the code is compiled"
  def calls(_opts \\ []) do
    []
  end

  defp callers(callee, opts) do
    module = parse_callee(callee)

    file_callers =
      for source <- sources(opts),
          reference = reference(module, source),
          do: {source(source, :source), reference}

    for {file, type} <- Enum.sort(file_callers) do
      Mix.shell().info([file, " (", type, ")"])
    end

    :ok
  end

  defp graph(opts) do
    write_graph(file_references(opts), excluded(opts), opts)

    :ok
  end

  ## Callers

  defp parse_callee(callee) do
    case Mix.Utils.parse_mfa(callee) do
      {:ok, [module]} -> module
      _ -> Mix.raise("xref callers MODULE expects a MODULE, got: " <> callee)
    end
  end

  defp reference(module, source) do
    cond do
      module in source(source, :compile_references) -> "compile"
      module in source(source, :struct_references) -> "struct"
      module in source(source, :runtime_references) -> "runtime"
      true -> nil
    end
  end

  ## Graph

  defp excluded(opts) do
    opts
    |> Keyword.get_values(:exclude)
    |> Enum.flat_map(&[{&1, nil}, {&1, :compile}, {&1, :struct}])
  end

  defp label_filter(nil), do: :all
  defp label_filter("compile"), do: :compile
  defp label_filter("struct"), do: :struct
  defp label_filter("runtime"), do: nil
  defp label_filter(other), do: Mix.raise("unknown --label #{other}")

  defp file_references(opts) do
    filter = label_filter(opts[:label])

    module_sources =
      for manifest_path <- manifests(opts),
          manifest_data = read_manifest(manifest_path, ""),
          module(module: module, sources: sources) <- manifest_data,
          source <- sources,
          source = Enum.find(manifest_data, &match?(source(source: ^source), &1)),
          do: {module, source}

    all_modules = MapSet.new(module_sources, &elem(&1, 0))

    Map.new(module_sources, fn {current, source} ->
      source(
        runtime_references: runtime,
        struct_references: structs,
        compile_references: compile,
        source: file
      ) = source

      compile_references =
        modules_to_nodes(compile, :compile, current, source, module_sources, all_modules, filter)

      struct_references =
        modules_to_nodes(structs, :struct, current, source, module_sources, all_modules, filter)

      runtime_references =
        modules_to_nodes(runtime, nil, current, source, module_sources, all_modules, filter)

      references =
        runtime_references
        |> Map.merge(struct_references)
        |> Map.merge(compile_references)
        |> Enum.to_list()

      {file, references}
    end)
  end

  defp modules_to_nodes(_, label, _, _, _, _, filter) when filter != :all and label != filter do
    %{}
  end

  defp modules_to_nodes(modules, label, current, source, module_sources, all_modules, _filter) do
    for module <- modules,
        module != current,
        module in all_modules,
        module_sources[module] != source,
        do: {source(module_sources[module], :source), label},
        into: %{}
  end

  defp write_graph(file_references, excluded, opts) do
    {root, file_references} =
      case {opts[:source], opts[:sink]} do
        {nil, nil} ->
          {Enum.map(file_references, &{elem(&1, 0), nil}) -- excluded, file_references}

        {source, nil} ->
          if file_references[source] do
            {Map.get(file_references, source, []), file_references}
          else
            Mix.raise("Source could not be found: #{source}")
          end

        {nil, sink} ->
          if file_references[sink] do
            file_references = filter_for_sink(file_references, sink)

            roots =
              file_references
              |> Map.delete(sink)
              |> Enum.map(&{elem(&1, 0), nil})

            {roots -- excluded, file_references}
          else
            Mix.raise("Sink could not be found: #{sink}")
          end

        {_, _} ->
          Mix.raise("mix xref graph expects only one of --source and --sink")
      end

    callback = fn {file, type} ->
      children = if opts[:only_nodes], do: [], else: Map.get(file_references, file, [])
      type = type && "(#{type})"
      {{file, type}, children -- excluded}
    end

    case opts[:format] do
      "dot" ->
        Mix.Utils.write_dot_graph!("xref_graph.dot", "xref graph", root, callback, opts)

        """
        Generated "xref_graph.dot" in the current directory. To generate a PNG:

           dot -Tpng xref_graph.dot -o xref_graph.png

        For more options see http://www.graphviz.org/.
        """
        |> String.trim_trailing()
        |> Mix.shell().info()

      "stats" ->
        stats(file_references)

      _ ->
        Mix.Utils.print_tree(root, callback, opts)
    end
  end

  defp filter_for_sink(file_references, sink) do
    file_references
    |> invert_references()
    |> apply_filter_for_sink([{sink, nil}], %{})
    |> invert_references()
  end

  defp apply_filter_for_sink(file_references, new_nodes, acc) do
    Enum.reduce(new_nodes, acc, fn {new_node_name, _type}, acc ->
      new_nodes = file_references[new_node_name]

      if acc[new_node_name] || !new_nodes do
        acc
      else
        apply_filter_for_sink(file_references, new_nodes, Map.put(acc, new_node_name, new_nodes))
      end
    end)
  end

  defp invert_references(file_references) do
    Enum.reduce(file_references, %{}, fn {file, references}, acc ->
      Enum.reduce(references, acc, fn {reference, type}, acc ->
        Map.update(acc, reference, [{file, type}], &[{file, type} | &1])
      end)
    end)
  end

  defp stats(references) do
    shell = Mix.shell()

    counters =
      Enum.reduce(references, %{compile: 0, struct: 0, nil: 0}, fn {_, deps}, acc ->
        Enum.reduce(deps, acc, fn {_, value}, acc ->
          Map.update!(acc, value, &(&1 + 1))
        end)
      end)

    shell.info("Tracked files: #{map_size(references)} (nodes)")
    shell.info("Compile dependencies: #{counters.compile} (edges)")
    shell.info("Structs dependencies: #{counters.struct} (edges)")
    shell.info("Runtime dependencies: #{counters.nil} (edges)")

    outgoing =
      references
      |> Enum.map(fn {file, deps} -> {length(deps), file} end)
      |> Enum.sort()
      |> Enum.take(-10)
      |> Enum.reverse()

    shell.info("\nTop #{length(outgoing)} files with most outgoing dependencies:")
    for {count, file} <- outgoing, do: shell.info("  * #{file} (#{count})")

    incoming =
      references
      |> Enum.reduce(%{}, fn {_, deps}, acc ->
        Enum.reduce(deps, acc, fn {file, _}, acc ->
          Map.update(acc, file, 1, &(&1 + 1))
        end)
      end)
      |> Enum.map(fn {file, count} -> {count, file} end)
      |> Enum.sort()
      |> Enum.take(-10)
      |> Enum.reverse()

    shell.info("\nTop #{length(incoming)} files with most incoming dependencies:")
    for {count, file} <- incoming, do: shell.info("  * #{file} (#{count})")
  end

  ## Helpers

  defp sources(opts) do
    for manifest <- manifests(opts),
        source() = source <- read_manifest(manifest, ""),
        do: source
  end

  defp manifests(opts) do
    siblings =
      if opts[:include_siblings] do
        for %{scm: Mix.SCM.Path, opts: opts} <- Mix.Dep.cached(),
            opts[:in_umbrella],
            do: Path.join([opts[:build], ".mix", @manifest])
      else
        []
      end

    [Path.join(Mix.Project.manifest_path(), @manifest) | siblings]
  end
end
