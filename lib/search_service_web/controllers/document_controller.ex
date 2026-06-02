defmodule SearchServiceWeb.DocumentController do
  @moduledoc """
  Handles document ingestion and index rebuilds.
  """

  use Phoenix.Controller, formats: [:json]

  alias SearchService.IndexServer

  @known_fields ~w(product_name shop_name name description)

  defp safe_field(nil), do: :name

  defp safe_field(field) when is_binary(field) do
    if field in @known_fields do
      String.to_atom(field)
    else
      :name
    end
  end

  def create(conn, params) do
    docs =
      case params do
        %{"documents" => docs} when is_list(docs) -> docs
        %{"document" => doc} -> [doc]
        doc when is_map(doc) and map_size(doc) > 0 -> [doc]
        _ -> []
      end

    if docs == [] do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Missing 'documents' or 'document' field"})
    else
      Enum.each(docs, fn doc ->
        IndexServer.insert(%{
          id: doc["id"],
          text: doc["text"],
          field: safe_field(doc["field"]),
          weight: doc["weight"] || 1.0
        })
      end)

      IndexServer.apply_batch_changes()

      conn
      |> put_status(:accepted)
      |> json(%{status: "queued", count: length(docs)})
    end
  end

  def delete(conn, %{"id" => id}) do
    IndexServer.delete(id)
    IndexServer.apply_batch_changes()

    conn
    |> put_status(:ok)
    |> json(%{status: "deleted", id: id})
  end

  def rebuild(conn, params) do
    documents =
      case params do
        %{"documents" => docs} when is_list(docs) ->
          Enum.map(docs, fn doc ->
            %{
              id: doc["id"],
              text: doc["text"],
              field: safe_field(doc["field"]),
              weight: doc["weight"] || 1.0
            }
          end)

        _ ->
          []
      end

    _result = IndexServer.rebuild(documents)

    conn
    |> put_status(:ok)
    |> json(%{status: "rebuilt", document_count: length(documents)})
  end

  def snapshot(conn, _params) do
    case IndexServer.snapshot() do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{status: "saved"})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "snapshot failed: #{reason}"})
    end
  end
end
