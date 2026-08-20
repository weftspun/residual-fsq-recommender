# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee

defmodule Recommender.Adapters.RemoteStore do
  @moduledoc """
  Remote SQL persistence for the `rfr` CLI.

  The connection comes from the caller. `with_db/2` opens one against `:db_url`, runs the
  caller's function, and closes it. Nothing is provisioned, started or stopped.

  This replaced an embedded single-node CockroachDB. `--db-url` already existed, as a way to
  point at an external server instead of the bundled one, so the change made the exception the
  only path rather than inventing a new one.

  The SQL is portable, which it was not before. `UPSERT INTO` is CockroachDB syntax, and the
  schema said `STRING` and `INT`, which PostgreSQL does not take. Both are now spelled the way
  the standard spells them, so the remote can be PostgreSQL today and something else later
  without touching this file.

  Schema — items are semantic IDs, transitions the hetero-associative counts:

      items(item_id TEXT PRIMARY KEY, t0 INTEGER, t1 INTEGER, t2 INTEGER, t3 INTEGER)
      transitions(prev TEXT, next TEXT, n INTEGER, PRIMARY KEY (prev, next))
  """

  @type opts :: %{
          optional(:data_dir) => String.t(),
          optional(:db_url) => String.t() | nil
        }

  @doc "Where the connection URL comes from when `--db-url` is absent."
  def db_url_env, do: "RFR_DB_URL"

  @doc "Default data directory (override with `--data-dir` or `RFR_DATA_DIR`)."
  def default_data_dir do
    System.get_env("RFR_DATA_DIR") ||
      Path.join(System.user_home!(), ".residual-fsq-recommender")
  end

  @doc """
  Run `fun.(conn)` against the remote store, opening one connection and closing it after.
  Ensures the schema first. Returns `fun`'s result, or `{:error, reason}`.

  The URL comes from `:db_url`, then `RFR_DB_URL`. There is no default and no fallback: a
  missing URL is an error rather than a quietly started local database, because the whole
  point of the change was that this command no longer runs a database of its own.
  """
  @spec with_db(opts(), (pid() -> result)) :: result | {:error, term()} when result: var
  def with_db(opts \\ %{}, fun) do
    case url(opts) do
      nil ->
        {:error,
         "no database URL. Pass --db-url, or set #{db_url_env()}, " <>
           "for example postgres://user:pass@host:5432/rfr"}

      url ->
        case Postgrex.start_link(parse(url)) do
          {:ok, conn} ->
            try do
              :ok = ensure_schema(conn)
              fun.(conn)
            after
              GenServer.stop(conn)
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp url(opts), do: opts[:db_url] || System.get_env(db_url_env())

  # Postgrex takes a keyword list. A URL is the one form a caller can put in an environment
  # variable without spelling five settings.
  defp parse(url) do
    uri = URI.parse(url)
    [user, pass] = String.split(uri.userinfo || ":", ":", parts: 2)

    [
      hostname: uri.host || "127.0.0.1",
      port: uri.port || 5432,
      username: user,
      password: pass,
      database: String.trim_leading(uri.path || "/rfr", "/")
    ]
  end

  ## Item / transition persistence (Recommender.Ports.ItemSink / ItemSource)

  @behaviour Recommender.Ports.ItemSink
  @behaviour Recommender.Ports.ItemSource

  @impl Recommender.Ports.ItemSink
  def upsert_item(conn, item_id, [t0, t1, t2, t3]) do
    Postgrex.query!(
      conn,
      """
      INSERT INTO items (item_id, t0, t1, t2, t3) VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (item_id) DO UPDATE
        SET t0 = EXCLUDED.t0, t1 = EXCLUDED.t1, t2 = EXCLUDED.t2, t3 = EXCLUDED.t3
      """,
      [item_id, t0, t1, t2, t3]
    )

    :ok
  end

  @impl Recommender.Ports.ItemSink
  def record_transition(conn, prev, next) do
    Postgrex.query!(
      conn,
      """
      INSERT INTO transitions (prev, next, n) VALUES ($1, $2, 1)
      ON CONFLICT (prev, next) DO UPDATE SET n = transitions.n + 1
      """,
      [prev, next]
    )

    :ok
  end

  @impl Recommender.Ports.ItemSource
  def list_items(conn, limit) do
    sql = "SELECT item_id, t0, t1, t2, t3 FROM items ORDER BY item_id" <> limit_clause(limit)

    for [id, t0, t1, t2, t3] <- Postgrex.query!(conn, sql, []).rows do
      {id, [t0, t1, t2, t3]}
    end
  end

  @impl Recommender.Ports.ItemSource
  def list_transitions(conn) do
    for [prev, next, n] <-
          Postgrex.query!(conn, "SELECT prev, next, n FROM transitions", []).rows do
      {prev, next, n}
    end
  end

  ## Schema + option mapping

  defp ensure_schema(conn) do
    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS items (
        item_id TEXT PRIMARY KEY,
        t0 INTEGER NOT NULL, t1 INTEGER NOT NULL, t2 INTEGER NOT NULL, t3 INTEGER NOT NULL
      )
      """,
      []
    )

    Postgrex.query!(
      conn,
      """
      CREATE TABLE IF NOT EXISTS transitions (
        prev TEXT NOT NULL, next TEXT NOT NULL, n INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (prev, next)
      )
      """,
      []
    )

    :ok
  end

  defp limit_clause(nil), do: ""
  defp limit_clause(n) when is_integer(n) and n > 0, do: " LIMIT #{n}"
end
