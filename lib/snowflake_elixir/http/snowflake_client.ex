defmodule SnowflakeEx.HTTPClient do
  @moduledoc ~S"""
  Helper library for interacting with Snowflakes REST API. This should not be called directly, use the
  `SnowflakeEx.SnowflakeConnectionServer` module instead, as it will use a GenServer.
  """
  require Logger

  @doc ~S"""
  Logs into Snowflake, returning a token and Session ID. The token can be used for querying in future.
  """
  @spec login(String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), String.t(), []) :: {:ok, %{token: String.t(), session_id: String.t()}} | {:error, String.t()}
  def login(host, account_name, warehouse, database, schema, username, password, role, snowflake_options) do
    data = %{
      data: %{
        ACCOUNT_NAME: account_name,
        PASSWORD: password,
        CLIENT_APP_ID: "JavaScript",
        CLIENT_APP_VERSION: "1.5.3",
        LOGIN_NAME: username,
        SESSION_PARAMETERS: Map.merge(%{
          VALIDATE_DEFAULT_PARAMETERS: true,
          QUOTED_IDENTIFIERS_IGNORE_CASE: true
        }, snowflake_options),
        CLIENT_ENVIRONMENT: %{
          schema: schema,
          tracing: "DEBUG",
          OS: "Linux",
          OCSP_MODE: "FAIL_OPEN",
          APPLICATION: "SnowflakeEx",
          warehouse: warehouse,
          database: database,
          serverURL: host,
          user: username,
          account: account_name
        }
      }
    }

    HTTPoison.post!(
      "#{host}/session/v1/login-request?databaseName=#{database}&schemaName=#{schema}&warehouse=#{
        warehouse
      }&roleName=#{role}",
      Jason.encode!(data),
      [
        {"Content-Type", "application/json"},
        {"'Accept", "application/json"}
      ],
      hackney: [
        :insecure,
        pool: :snowflake_pool,
        timeout: 180_000,
      ],
      recv_timeout: 180_000
    )
    |> Map.get(:body)
    |> Jason.decode!()
    |> process_login()
  end

  @doc ~S"""
  Runs a query from a string, then returns the result in a %SnowflakeEx.Result{} struct.
  """
  @spec query(String.t(), String.t(), String.t(), Keyword.t()) :: %SnowflakeEx.Result{}
  def query(host, token, query, opts) do
    params = Keyword.get(opts, :params, [])
    async = Keyword.get(opts, :async, false)

    run_query(host, token, query, params, async)
  end

  def insert(host, token, query, _params, connect_opts) do
    HTTPoison.post!(
      snowflake_query_url(host),
      snowflake_insert_headers(query, Keyword.get(connect_opts, :field_types, %{})),
      [
        {"Content-Type", "application/json"},
        {"accept", "application/snowflake"},
        {"Authorization", "Snowflake Token=\"#{token}\""}
      ],
      hackney: [
        :insecure,
        pool: :snowflake_pool,
        timeout: 180_000,
      ],
      recv_timeout: 180_000
    )
    |> Map.get(:body)
    |> Jason.decode!()
    |> process_response()
  end

  defp monitor_query_id(monitor_id, host, token, num) when num < 1000 do
    :timer.sleep(50)

    response = HTTPoison.get!(
      "#{host}/queries/#{monitor_id}/result",
      [
        {"Content-Type", "application/json"},
        {"accept", "application/snowflake"},
        {"Authorization", "Snowflake Token=\"#{token}\""}
      ],
      hackney: [
        :insecure,
        pool: :snowflake_pool,
        timeout: 180_000,
      ],
      recv_timeout: 180_000
    )

    if Map.get(response, :body, "") == "" do
      monitor_query_id(monitor_id, host, token, num + 1)
    else
      response
      |> process_query(false)
    end
  end

  defp monitor_query_id(_monitor_id, _host, _token, num) do
    {:error, "failed after #{num} attempts"}
  end

  defp s3_download(url, encryption_key, encryption_key_md5) do
    HTTPoison.get!(
      url,
      [
        {"accept", "application/snowflake"},
        {"Accept-Encoding", "gzip,deflate"},
        {"x-amz-server-side-encryption-customer-key", encryption_key},
        {"x-amz-server-side-encryption-customer-key-md5", encryption_key_md5}
      ],
      hackney: [
        :insecure,
        pool: :s3_pool
      ]
    )
    |> Map.get(:body)
    |> :zlib.gunzip()
  end

  defp run_query(host, token, query, [], false) do
    HTTPoison.post!(
      snowflake_query_url(host),
      snowflake_query_headers(query, false),
      [
        {"Content-Type", "application/json"},
        {"accept", "application/snowflake"},
        {"Authorization", "Snowflake Token=\"#{token}\""}
      ],
      hackney: [
        :insecure,
        pool: :snowflake_pool,
        timeout: 180_000,
      ],
      recv_timeout: 180_000
    )
    |> process_query()
  end

  # Executes a query, then monitors the response.
  defp run_query(host, token, query, [], true) do
    HTTPoison.post!(
      snowflake_query_url(host),
      snowflake_query_headers(query, true),
      [
        {"Content-Type", "application/json"},
        {"accept", "application/snowflake"},
        {"Authorization", "Snowflake Token=\"#{token}\""}
      ],
      hackney: [
        :insecure,
        pool: :snowflake_pool,
        timeout: 180_000,
      ],
      recv_timeout: 180_000
    )
    |> Map.get(:body)
    |> Jason.decode!()
    |> Map.get("data")
    |> Map.get("queryId")
    |> monitor_query_id(host, token, 1)
  end

  defp run_query(host, token, query, _params, true) do
    HTTPoison.post!(
      snowflake_query_url(host),
      snowflake_query_headers(query, false),
      [
        {"Content-Type", "application/json"},
        {"accept", "application/snowflake"},
        {"Authorization", "Snowflake Token=\"#{token}\""}
      ],
      hackney: [
        :insecure,
        pool: :snowflake_pool,
        timeout: 180_000,
      ],
      recv_timeout: 180_000
    )
    |> Map.get(:body)
    |> Jason.decode!()
  end

  # Decodes a column type of null to nil
  defp decode_column(%{"scale" => 0, "type" => "fixed", "byteLength" => nil}, nil) do
    nil
  end

  # Decodes an integer column type
  defp decode_column(%{"scale" => 0, "type" => "fixed", "byteLength" => nil}, value) do
    case Integer.parse(value) do
      {num, ""} ->
        num

      _ ->
        value
    end
  end

  # for everything else, just return the value
  defp decode_column(_, value), do: value

  defp process_query(%{status_code: 200, body: body} = bar) do
    body
    |> Jason.decode!()
    |> process_response()
  end

  defp process_query(_, _), do: {:error, "error"}

  defp process_response(%{"success" => true} = data) do
    IO.inspect(data)
    data
    |> Map.get("data")
    |> Map.get("queryResultFormat")
    |> IO.inspect()
    |> process_query_result_format(data["data"])
  end

  defp process_response(%{"success" => false, "message" => message, "code" => error_code, "data" => %{"sqlState" => sql_error}}, _) do
    {:error, %SnowflakeEx.Result{success: false, messages: [%{message: message, severity: :error, error_code: error_code, sql_error: sql_error}]}}
  end

  # Invalid session errors will not have anything in the `data` key.
  defp process_response(%{"success" => false, "message" => message, "code" => error_code}, _) do
    {:error, %SnowflakeEx.Result{success: false, messages: [%{message: message, severity: :error, error_code: error_code, sql_error: nil}]}}
  end

  defp process_query_result_format(
         "json",
         %{
           "rowset" => [],
           "rowtype" => row_type,
           "total" => total,
           "chunks" => chunks,
           "chunkHeaders" => %{
             "x-amz-server-side-encryption-customer-key" => key,
             "x-amz-server-side-encryption-customer-key-md5" => md5
           }
         } = data
       ) do
    urls = Enum.map(chunks, fn %{"url" => url} -> url end)
    parsed = Task.async_stream(urls, fn(url) -> s3_download(url, key, md5) end, max_concurrency: 10)
        |> Enum.map(fn({:ok, result}) -> result end)
        |> Enum.join(", ")

    rows = Jason.decode!("[#{parsed}]")

    row_data = process_row_data(rows, row_type)

    columns = Enum.map(row_type, fn %{"name" => name} -> name end)

    {:ok, %SnowflakeEx.Result{success: false, rows: row_data, columns: columns, num_rows: total, metadata: data, messages: %{message: row_data, severity: :debug}}}
  end

  defp process_query_result_format(
         "json",
         %{
           "rowset" => rowset,
           "rowtype" => row_type,
           "total" => total,
           "chunks" => chunks,
           "chunkHeaders" => %{
             "x-amz-server-side-encryption-customer-key" => key,
             "x-amz-server-side-encryption-customer-key-md5" => md5
           }
         } = data
       ) do
    parsed =
        chunks
        |> Enum.map(fn %{"url" => url} -> url end)
        |> Task.async_stream(fn(url) -> s3_download(url, key, md5) end, max_concurrency: 10)
        |> Enum.map(fn({:ok, result}) -> result end)
        |> Enum.join(", ")

    rows = Jason.decode!("[#{parsed}]")

    row_data = process_row_data(rowset, row_type) ++ process_row_data(rows, row_type)

    columns = Enum.map(row_type, fn %{"name" => name} -> name end)

    {:ok, %SnowflakeEx.Result{success: false, rows: row_data, columns: columns, num_rows: total, metadata: data, messages: [%{message: row_data, severity: :info}]}}
  end

  defp process_query_result_format(
         "json",
         %{"rowset" => rows, "rowtype" => row_type, "total" => total} = data
       ) do
    row_data = process_row_data(rows, row_type)

    columns = Enum.map(row_type, fn %{"name" => name} -> name end)
    {:ok, %SnowflakeEx.Result{success: false, rows: row_data, columns: columns, num_rows: total, metadata: data, messages: [%{message: row_data, severity: :info}]}}
  end

  defp process_row_data(rows, row_type) do
    rows
    |> Stream.map(fn r ->
      r
      |> Stream.with_index()
      |> Stream.map(fn {rr, column_no} ->
        decode_column(Enum.at(row_type, column_no), rr)
      end)
      |> Enum.to_list()
    end)
    |> Enum.to_list()
  end

  defp uuid(host) do
    if String.contains?(host, "127.0.0.1"),
      do: "11111111-1111-1111-1111-111111111111",
      else: UUID.uuid4()
  end

  defp process_login(%{"success" => false, "message" => message}), do: {:error, message}

  defp process_login(%{
         "data" => %{
           "token" => token,
           "sessionId" => session_id
         }
       }),
       do: {:ok, %{token: token, session_id: session_id}}

  defp process_login(_), do: {:error, "Invalid user/pass or host."}

  defp snowflake_query_headers(query, async) when is_binary(query) and is_boolean(async) do
    %{
      sqlText: query,
      sequenceId: 0,
      bindings: nil,
      bindStage: nil,
      describeOnly: false,
      parameters: %{
        CLIENT_RESULT_CHUNK_SIZE: 48
      },
      describedJobId: nil,
      isInternal: false,
      asyncExec: false
    }
    |> Jason.encode!()
  end

  defp snowflake_insert_headers(query, bindings) when is_binary(query) and is_map(bindings) do
    %{
      sqlText: query,
      sequenceId: 0,
      bindings: bindings,
      bindStage: nil,
      describeOnly: false,
      parameters: %{
        CLIENT_RESULT_CHUNK_SIZE: 48
      },
      describedJobId: nil,
      isInternal: false,
      asyncExec: false
    }
    |> Jason.encode!()
  end

  defp snowflake_query_url(host) do
    "#{host}/queries/v1/query-request?requestId=#{uuid(host)}"
  end
end
