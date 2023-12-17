defmodule Boltx.Connection do
  @moduledoc false
  use DBConnection
  alias Boltx.Client
  alias Boltx.QueryStatement

  defstruct [
    :client,
    :server_version,
    :hints,
    :patch_bolt,
    :connection_id
  ]

  @impl true
  def connect(opts) do
    config = Client.Config.new(opts)

    with {:ok, %Client{} = client} <- Client.connect(config),
         {:ok, response_server_metadata} <- do_init(client, opts) do
      state = getServerMetadataState(response_server_metadata)
      state = %__MODULE__{state | client: client}
      {:ok, state}
    end
  end

  defp do_init(client, opts) do
    do_init(client.bolt_version, client, opts)
  end

  defp do_init(bolt_version, client, opts) when is_float(bolt_version) and bolt_version >= 5.1 do
    with {:ok, response_hello} <- Client.send_hello(client, opts),
         {:ok, _response_logon} <- Client.send_logon(client, opts) do
      {:ok, response_hello}
    end
  end

  defp do_init(bolt_version, client, opts) when is_float(bolt_version) and bolt_version >= 3.0 do
    Client.send_hello(client, opts)
  end

  defp do_init(bolt_version, client, opts) when is_float(bolt_version) and bolt_version <= 2.0 do
    Client.send_init(client, opts)
  end

  defp getServerMetadataState(response_metadata) do
    patch_bolt = Map.get(response_metadata, "patch_bolt", "")
    hints = Map.get(response_metadata, "hints", "")
    connection_id = Map.get(response_metadata, "connection_id", "")

    %__MODULE__{
      client: nil,
      server_version: response_metadata["server"],
      patch_bolt: patch_bolt,
      hints: hints,
      connection_id: connection_id
    }
  end

  @impl true
  def handle_begin(opts, %__MODULE__{client: client} = conn_data) do
    {:ok, _} = Client.send_begin(client, opts)
    {:ok, :began, conn_data}
  end

  @impl true
  def handle_commit(_, %__MODULE__{client: client} = conn_data) do
    {:ok, _} = Client.send_commit(client)
    {:ok, :committed, conn_data}
  end

  @impl true
  def handle_rollback(_, %__MODULE__{client: client} = conn_data) do
    {:ok, _} = Client.send_rollback(client)
    {:ok, :rolledback, conn_data}
  end

  @impl true
  def handle_execute(query, params, opts, conn_data) do
    execute(query, params, opts, conn_data)
  end

  defp execute(statement, params, extra_parameters, conn_data) do
    %QueryStatement{statement: query} = statement
    %__MODULE__{client: client} = conn_data

    case Client.run_statement(client, query, params, extra_parameters) do
      {:ok, statement_result} ->
        {:ok, statement, statement_result, conn_data}

      %Boltx.Error{code: error_code} = error
      when error_code in ~w(syntax_error semantic_error)a ->
        action =
          if client.bolt_version >= 3.0,
            do: &Client.send_reset/1,
            else: &Client.send_ack_failure/1

        action.(client)
        {:error, error, conn_data}
    end
  rescue
    e in Boltx.Error ->
      {:error, %{code: :failure, message: "#{e.message}, code: #{e.code}"}, conn_data}

    e ->
      {:error, %{code: :failure, message: to_string(e)}, conn_data}
  end

  @impl true
  def disconnect(_reason, state) do
    if state.client.bolt_version >= 3.0 do
      Client.send_goodbye(state.client)
    end

    Client.disconnect(state.client)
  end

  @impl true
  def checkout(state) do
    {:ok, state}
  end

  @impl true
  def ping(state) do
    {:ok, state}
  end

  @doc "Callback for DBConnection.checkin/1"
  def checkin(state) do
    case Client.disconnect(state.client) do
      :ok -> {:ok, state}
    end
  end

  @impl true
  def handle_prepare(query, _opts, state), do: {:ok, query, state}
  @impl true
  def handle_close(query, _opts, state), do: {:ok, query, state}
  @impl true
  def handle_deallocate(query, _cursor, _opts, state), do: {:ok, query, state}
  @impl true
  def handle_declare(query, _params, _opts, state), do: {:ok, query, state, nil}
  @impl true
  def handle_fetch(query, _cursor, _opts, state), do: {:cont, query, state}
  @impl true
  def handle_status(_opts, state), do: {:idle, state}
end
