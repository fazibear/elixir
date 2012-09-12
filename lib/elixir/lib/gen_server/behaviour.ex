defmodule GenServer.Behavior do
  @moduledoc false

  defmacro __using__(_) do
    IO.puts "Using GenServer.Behavior is deprecated, use GenServer.Behaviour instead"
    quote do
      use GenServer.Behaviour
    end
  end
end

defmodule GenServer.Behaviour do
  @moduledoc """
  By using this module, you get default GenServer callbacks
  for `handle_call`, `handle_info`, `handle_cast`, `terminate`
  and `code_change`. `init` still needs to be implemented by the
  developer. Since these functions are defined as overridable,
  they can be partially customized and have a general clause
  that simply invokes `super`.

  This module also tags the behavior as :gen_server. For more
  information on gen_server, please refer to the Erlang
  documentation:

  http://www.erlang.org/doc/man/gen_server.html
  http://www.erlang.org/doc/design_principles/gen_server_concepts.html

  ## Example

      defmodule MyServer do
        use GenServer.Behaviour

        # Callbacks

        def init(state) do
          { :ok, state }
        end

        def handle_call(:peek, _from, [h|_] = state) do
          { :reply, h, state }
        end

        # Default behaviour
        def handle_call(request, from, config) do
          super(request, from, config)
        end

        def handle_cast({ :push, item }, state) do
          { :noreply, [item|state] }
        end

        # Default cast behaviour
        def handle_cast(request, config) do
          super(request, config)
        end
      end

  """

  @doc false
  defmacro __using__(_) do
    quote location: :keep do
      @behavior :gen_server

      def handle_call(_request, _from, state) do
        { :reply, :undef, state }
      end

      def handle_info(_msg, state) do
        { :noreply, state }
      end

      def handle_cast(_msg, state) do
        { :noreply, state }
      end

      def terminate(reason, state) do
        :ok
      end

      def code_change(_old, state, _extra) do
        { :ok, state }
      end

      defoverridable [handle_call: 3, handle_info: 2, handle_cast: 2, terminate: 2, code_change: 3]
    end
  end
end