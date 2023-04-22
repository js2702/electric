defmodule Electric.Satellite.SerializationTest do
  alias Electric.Satellite.Serialization

  use Electric.Satellite.Protobuf
  use ExUnit.Case, async: true

  alias Electric.Replication.Changes.Transaction

  alias Electric.Postgres.Lsn

  test "test row serialization" do
    data = %{"not_null" => <<"4">>, "null" => nil, "not_present" => <<"some other value">>}
    columns = ["null", "this_columns_is_empty", "not_null"]

    serialized_data = Serialization.map_to_row(data, columns)

    expected = %SatOpRow{
      nulls_bitmask: <<1::1, 1::1, 0::1, 0::5>>,
      values: [<<>>, <<>>, <<"4">>]
    }

    assert serialized_data == expected
  end

  test "test row deserialization" do
    deserialized_data =
      Serialization.row_to_map(
        ["null", "this_columns_is_empty", "not_null"],
        %SatOpRow{nulls_bitmask: <<1::1, 1::1, 0::1, 0::5>>, values: [<<>>, <<>>, <<"4">>]}
      )

    expected = %{"not_null" => <<"4">>, "null" => nil, "this_columns_is_empty" => nil}

    assert deserialized_data == expected
  end

  test "test row deserialization with long bitmask" do
    mask = <<0b1101000010000000::16>>

    deserialized_data =
      Serialization.row_to_map(
        Enum.map(0..8, &"bit#{&1}"),
        %SatOpRow{nulls_bitmask: mask, values: Enum.map(0..8, fn _ -> "" end)}
      )

    expected = %{
      "bit0" => nil,
      "bit1" => nil,
      "bit2" => "",
      "bit3" => nil,
      "bit4" => "",
      "bit5" => "",
      "bit6" => "",
      "bit7" => "",
      "bit8" => nil
    }

    assert deserialized_data == expected
  end

  test "test row serialization 2" do
    data = %{
      "content" => "hello from pg_1",
      "content_text_null" => nil,
      "content_text_null_default" => "",
      "id" => "f989b58b-980d-4d3c-b178-adb6ae8222f1",
      "intvalue_null" => nil,
      "intvalue_null_default" => "10"
    }

    columns = [
      "id",
      "content",
      "content_text_null",
      "content_text_null_default",
      "intvalue_null",
      "intvalue_null_default"
    ]

    serialized_data = Serialization.map_to_row(data, columns)

    expected = %SatOpRow{
      nulls_bitmask: <<0::1, 0::1, 1::1, 0::1, 1::1, 0::3>>,
      values: ["f989b58b-980d-4d3c-b178-adb6ae8222f1", "hello from pg_1", "", "", "", "10"]
    }

    assert serialized_data == expected
  end

  defmodule StateList do
    @behaviour Electric.Replication.Postgres.ServerState

    @impl true
    def connect(conn_config, opts) do
      opts = Map.new(opts)
      notify(opts, {:connect, conn_config})
      {:ok, {[], opts}}
    end

    @impl true
    def load({[], opts}) do
      notify(opts, :load)
      {:ok, nil}
    end

    def load({[{version, schema} | _versions], opts}) do
      notify(opts, {:load, version, schema})
      {:ok, schema}
    end

    @impl true
    def save({versions, opts}, version, schema) do
      notify(opts, {:save, version, schema})
      {:ok, {[{version, schema} | versions], opts}}
    end

    defp notify(%{parent: parent}, msg) when is_pid(parent) do
      send(parent, {__MODULE__, msg})
    end
  end

  describe "migrations" do
    test "writes to electric ddl table are recognised as migration ops" do
      origin = "postgres_1"
      version = "20220421"

      tx = %Transaction{
        changes: [
          %Electric.Replication.Changes.UpdatedRecord{
            relation: {"electric", "ddl_commands"},
            old_record: nil,
            record: %{
              "id" => "6",
              "query" => "create table something_else (id uuid primary key);",
              "txid" => "749",
              "txts" => "2023-04-20 19:41:56.236357+00",
              "version" => version
            },
            tags: ["postgres_1@1682019749178"]
          },
          %Electric.Replication.Changes.UpdatedRecord{
            relation: {"electric", "ddl_commands"},
            old_record: nil,
            record: %{
              "id" => "7",
              "query" => "create table other_thing (id uuid primary key);",
              "txid" => "749",
              "txts" => "2023-04-20 19:41:56.236357+00",
              "version" => version
            },
            tags: ["postgres_1@1682019749178"]
          },
          %Electric.Replication.Changes.UpdatedRecord{
            relation: {"electric", "ddl_commands"},
            old_record: nil,
            record: %{
              "id" => "8",
              "query" => "create table yet_another_thing (id uuid primary key);",
              "txid" => "749",
              "txts" => "2023-04-20 19:41:56.236357+00",
              "version" => version
            },
            tags: ["postgres_1@1682019749178"]
          },
          %Electric.Replication.Changes.UpdatedRecord{
            relation: {"electric", "migration_versions"},
            old_record: nil,
            record: %{
              "txid" => "749",
              "txts" => "2023-04-20 19:41:56.236357+00",
              "version" => version
            },
            tags: ["postgres_1@1682019749178"]
          }
        ],
        commit_timestamp: ~U[2023-04-20 14:05:31.416063Z],
        origin: origin,
        publication: "all_tables",
        lsn: %Lsn{segment: 0, offset: 0},
        origin_type: :postgresql
      }

      {:ok, _pid} =
        start_supervised(
          {Electric.Replication.Postgres.ServerState,
           {[origin: origin], [backend: {StateList, parent: self()}]}}
        )

      assert_receive {StateList, {:connect, [origin: ^origin]}}

      {oplog, [], %{}} = Serialization.serialize_trans(tx, 1, %{})

      # no schema to load
      assert_receive {StateList, :load}
      assert_receive {StateList, {:save, ^version, schema}}
      # only receive 1 save instruction
      refute_receive {StateList, {:save, _, _schema}}

      assert %SatOpLog{ops: ops} = oplog

      assert [
               %SatTransOp{op: {:begin, %SatOpBegin{is_migration: true}}},
               %SatTransOp{op: {:migrate, %SatOpMigrate{} = migration1}},
               %SatTransOp{op: {:migrate, %SatOpMigrate{} = migration2}},
               %SatTransOp{op: {:migrate, %SatOpMigrate{} = migration3}},
               %SatTransOp{op: {:commit, %SatOpCommit{}}}
             ] = ops

      assert %SatOpMigrate{
               stmts: [
                 %SatOpMigrate.Stmt{type: :CREATE_TABLE, sql: sql1}
               ],
               table: %SatOpMigrate.Table{
                 name: "something_else",
                 columns: [%SatOpMigrate.Column{name: "id", sqlite_type: "BLOB"}],
                 fks: [],
                 pks: ["id"]
               }
             } = migration1

      assert sql1 =~ ~r/^CREATE TABLE "something_else"/

      assert %SatOpMigrate{
               stmts: [
                 %SatOpMigrate.Stmt{type: :CREATE_TABLE, sql: sql2}
               ],
               table: %SatOpMigrate.Table{
                 name: "other_thing",
                 columns: [%SatOpMigrate.Column{name: "id", sqlite_type: "BLOB"}],
                 fks: [],
                 pks: ["id"]
               }
             } = migration2

      assert sql2 =~ ~r/^CREATE TABLE "other_thing"/

      assert %SatOpMigrate{
               stmts: [
                 %SatOpMigrate.Stmt{type: :CREATE_TABLE, sql: sql3}
               ],
               table: %SatOpMigrate.Table{
                 name: "yet_another_thing",
                 columns: [%SatOpMigrate.Column{name: "id", sqlite_type: "BLOB"}],
                 fks: [],
                 pks: ["id"]
               }
             } = migration3

      assert sql3 =~ ~r/^CREATE TABLE "yet_another_thing"/

      assert Enum.map(schema.tables, & &1.name.name) == [
               "something_else",
               "other_thing",
               "yet_another_thing"
             ]
    end
  end

  test "pg-only migrations are not serialized" do
    origin = "postgres_1"
    version = "20220421"

    tx = %Transaction{
      changes: [
        %Electric.Replication.Changes.UpdatedRecord{
          relation: {"electric", "ddl_commands"},
          old_record: nil,
          record: %{
            "id" => "6",
            "query" =>
              "CREATE SUBSCRIPTION \"postgres_2\" CONNECTION 'host=electric_1 port=5433 dbname=test connect_timeout=5000' PUBLICATION \"all_tables\" WITH (connect = false)",
            "txid" => "749",
            "txts" => "2023-04-20 19:41:56.236357+00",
            "version" => version
          },
          tags: ["postgres_1@1682019749178"]
        },
        %Electric.Replication.Changes.UpdatedRecord{
          relation: {"electric", "ddl_commands"},
          old_record: nil,
          record: %{
            "id" => "7",
            "query" => "ALTER SUBSCRIPTION \"postgres_1\" ENABLE",
            "txid" => "749",
            "txts" => "2023-04-20 19:41:56.236357+00",
            "version" => version
          },
          tags: ["postgres_1@1682019749178"]
        },
        %Electric.Replication.Changes.UpdatedRecord{
          relation: {"electric", "ddl_commands"},
          old_record: nil,
          record: %{
            "id" => "8",
            "query" =>
              "ALTER SUBSCRIPTION \"postgres_1\" REFRESH PUBLICATION WITH (copy_data = false)",
            "txid" => "749",
            "txts" => "2023-04-20 19:41:56.236357+00",
            "version" => version
          },
          tags: ["postgres_1@1682019749178"]
        },
        %Electric.Replication.Changes.UpdatedRecord{
          relation: {"electric", "migration_versions"},
          old_record: nil,
          record: %{
            "txid" => "749",
            "txts" => "2023-04-20 19:41:56.236357+00",
            "version" => version
          },
          tags: ["postgres_1@1682019749178"]
        }
      ],
      commit_timestamp: ~U[2023-04-20 14:05:31.416063Z],
      origin: origin,
      publication: "all_tables",
      lsn: %Lsn{segment: 0, offset: 0},
      origin_type: :postgresql
    }

    {:ok, _pid} =
      start_supervised(
        {Electric.Replication.Postgres.ServerState,
         {[origin: origin], [backend: {StateList, parent: self()}]}}
      )

    assert_receive {StateList, {:connect, [origin: ^origin]}}

    {oplog, [], %{}} = Serialization.serialize_trans(tx, 1, %{})

    assert %SatOpLog{ops: ops} = oplog

    assert [
             %SatTransOp{op: {:begin, %SatOpBegin{is_migration: true}}},
             %SatTransOp{op: {:commit, %SatOpCommit{}}}
           ] = ops
  end
end
