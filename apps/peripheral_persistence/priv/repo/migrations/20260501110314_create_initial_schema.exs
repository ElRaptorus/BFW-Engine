defmodule EvilEngine.Persistence.Repo.Migrations.CreateInitialSchema do
  @moduledoc """
  Single migration containing the full initial schema.

  Pre-alpha migration policy: this file is updated in-place whenever
  the schema changes. See `.cursor/skills/database-migrations/SKILL.md`.

  Contains:
  1. Ash/Postgres extension functions (uuid_generate_v7, ash_raise_error, etc.)
  2. Catalog tables (processes, process_versions)
  3. Execution tables (process_instances, flow_node_instances, gateway_pending_arrivals)
  4. Audit tables (process_instance_events, data_objects, data_object_writes)
  5. All indexes, constraints, and compression settings
  6. DMN catalog tables (decision_definitions, decision_versions)
  7. Operational Timer Start schedules (timer_start_schedules)
  """

  use Ecto.Migration

  @lz4_columns [
    {"process_instances", "started_with_context"},
    {"flow_node_instances", "input_token"},
    {"flow_node_instances", "output_token"},
    {"flow_node_instances", "type_properties"},
    {"gateway_pending_arrivals", "arrived_payload"},
    {"data_objects", "value"}
  ]

  @lz4_columns_partitioned [
    {"process_instance_events", "payload"},
    {"data_object_writes", "value"},
    {"messages", "payload"},
    {"pending_messages", "payload"}
  ]

  def up do
    # ---------------------------------------------------------------
    # 1. Ash/Postgres extension functions
    # ---------------------------------------------------------------

    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_or(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
    AS $$ SELECT COALESCE(NULLIF($1, FALSE), $2) $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_or(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
    AS $$ SELECT COALESCE($1, $2) $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_and(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
      SELECT CASE
        WHEN $1 IS TRUE THEN $2
        ELSE $1
      END $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_and(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
      SELECT CASE
        WHEN $1 IS NOT NULL THEN $2
        ELSE $1
      END $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_trim_whitespace(arr text[])
    RETURNS text[] AS $$
    DECLARE
        start_index INT = 1;
        end_index INT = array_length(arr, 1);
    BEGIN
        WHILE start_index <= end_index AND arr[start_index] = '' LOOP
            start_index := start_index + 1;
        END LOOP;

        WHILE end_index >= start_index AND arr[end_index] = '' LOOP
            end_index := end_index - 1;
        END LOOP;

        IF start_index > end_index THEN
            RETURN ARRAY[]::text[];
        ELSE
            RETURN arr[start_index : end_index];
        END IF;
    END; $$
    LANGUAGE plpgsql
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb)
    RETURNS BOOLEAN AS $$
    BEGIN
        RAISE EXCEPTION 'ash_error: %', json_data::text;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    STABLE
    SET search_path = '';
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb, type_signal ANYCOMPATIBLE)
    RETURNS ANYCOMPATIBLE AS $$
    BEGIN
        RAISE EXCEPTION 'ash_error: %', json_data::text;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    STABLE
    SET search_path = '';
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_required(value ANYCOMPATIBLE, payload jsonb)
    RETURNS ANYCOMPATIBLE AS $$
    BEGIN
      IF value IS NULL THEN
        RETURN ash_raise_error(payload, value);
      END IF;

      RETURN value;
    END;
    $$ LANGUAGE plpgsql
    STABLE
    SET search_path = '';
    """)

    execute("""
    CREATE OR REPLACE FUNCTION uuid_generate_v7()
    RETURNS UUID
    AS $$
    DECLARE
      timestamp    TIMESTAMPTZ;
      microseconds INT;
    BEGIN
      timestamp    = clock_timestamp();
      microseconds = (cast(extract(microseconds FROM timestamp)::INT - (floor(extract(milliseconds FROM timestamp))::INT * 1000) AS DOUBLE PRECISION) * 4.096)::INT;

      RETURN encode(
        set_byte(
          set_byte(
            overlay(uuid_send(gen_random_uuid()) placing substring(int8send(floor(extract(epoch FROM timestamp) * 1000)::BIGINT) FROM 3) FROM 1 FOR 6
          ),
          6, (b'0111' || (microseconds >> 8)::bit(4))::bit(8)::int
        ),
        7, microseconds::bit(8)::int
      ),
      'hex')::UUID;
    END
    $$
    LANGUAGE PLPGSQL
    SET search_path = ''
    VOLATILE;
    """)

    # ---------------------------------------------------------------
    # 2. Catalog tables
    # ---------------------------------------------------------------

    create table(:processes, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :process_model_id, :text, null: false
      add :name, :text
      add :enabled, :boolean, null: false, default: true
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:processes, [:process_model_id], name: "processes_process_model_id_unique_idx")

    create table(:process_versions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :process_id, references(:processes, type: :uuid, on_delete: :restrict),
        null: false

      add :version, :text, null: false
      add :definitions_id, :text
      add :bpmn_xml, :text
      add :deployer, :map
      add :deleted, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime_usec
      add :deleted_by, :map
      add :deployed_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:process_versions, [:process_id, :version],
             name: "process_versions_unique_process_version_index",
             where: "deleted = false"
           )

    create index(:process_versions, [:process_id],
             name: "process_versions_process_id_idx"
           )

    create constraint(:process_versions, :process_versions_deleted_consistency,
             check: """
               (deleted = false AND deleted_at IS NULL AND deleted_by IS NULL)
             OR (deleted = true AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL)
             """
           )

    create table(:timer_start_schedules, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :process_version_id,
          references(:process_versions, type: :uuid, on_delete: :delete_all),
          null: false

      add :process_model_id, :text, null: false
      add :flow_node_id, :text, null: false
      add :kind, :text, null: false
      add :iso_spec, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :next_fire_at, :utc_datetime_usec
      add :last_triggered_at, :utc_datetime_usec
      add :cycle_total, :integer
      add :cycle_remaining, :integer
      add :scheduler_ref, :text
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:timer_start_schedules, [:process_version_id, :flow_node_id],
             name: "timer_start_schedules_version_flow_node_index"
           )

    create index(:timer_start_schedules, [:enabled, :next_fire_at],
             name: "timer_start_schedules_armed_idx"
           )

    create constraint(:timer_start_schedules, :timer_start_schedules_kind_cycle,
             check: "kind = 'cycle'"
           )

    # ---------------------------------------------------------------
    # 3. Execution tables
    # ---------------------------------------------------------------

    create table(:process_instances, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :process_version_id, :uuid, null: false

      add :parent_process_instance_id, :uuid
      add :business_key, :text
      add :triggerer_flow_node_instance_id, :uuid
      add :state, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :started_by, :map
      add :started_with_context, :map
      add :error_info, :map
      add :deleted, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime_usec
      add :deleted_by, :map
    end

    create index(:process_instances, [:business_key], name: "process_instances_business_key_idx")

    create index(:process_instances, [:process_version_id, :state],
             name: "process_instances_version_state_idx"
           )

    create index(:process_instances, [:state],
             name: "process_instances_state_running_idx",
             where: "state = 'running'"
           )

    create index(:process_instances, [:parent_process_instance_id],
             name: "process_instances_parent_pi_id_idx",
             where: "parent_process_instance_id IS NOT NULL"
           )

    create constraint(:process_instances, :process_instances_deleted_consistency,
             check: """
               (deleted = false AND deleted_at IS NULL AND deleted_by IS NULL)
             OR (deleted = true AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL)
             """
           )

    create table(:gateway_pending_arrivals, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :process_instance_id, :uuid, null: false
      add :gateway_flow_node_instance_id, :uuid, null: false
      add :source_branch_sequence_flow_id, :text, null: false
      add :source_flow_node_instance_id, :uuid, null: false
      add :arrived_payload, :map, null: false
      add :arrived_at, :utc_datetime_usec, null: false
    end

    create index(:gateway_pending_arrivals, [:gateway_flow_node_instance_id],
             name: "gateway_pending_arrivals_gateway_flow_node_instance_idx"
           )

    create index(:gateway_pending_arrivals, [:process_instance_id],
             name: "gateway_pending_arrivals_process_instance_id_idx"
           )

    create unique_index(
             :gateway_pending_arrivals,
             [:gateway_flow_node_instance_id, :source_branch_sequence_flow_id],
             name: "gateway_pending_arrivals_unique_branch_arrival_index"
           )

    create table(:flow_node_instances, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :process_instance_id, :uuid, null: false
      add :flow_node_id, :text, null: false
      add :flow_node_type, :text, null: false
      add :event_type, :text
      add :lane_name, :text
      add :state, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :previous_flow_node_instance_ids, {:array, :uuid}, default: []
      add :triggerer_flow_node_instance_id, :uuid
      add :input_token, :map
      add :output_token, :map
      add :type_properties, :map
      add :error_info, :map
      add :multi_instance_id, :uuid
      add :iteration_index, :integer
      add :deleted, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime_usec
      add :deleted_by, :map
    end

    create constraint(:flow_node_instances, :flow_node_instances_deleted_consistency,
             check: """
               (deleted = false AND deleted_at IS NULL AND deleted_by IS NULL)
             OR (deleted = true AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL)
             """
           )

    create index(:flow_node_instances, [:flow_node_type, :state],
             name: "flow_node_instances_type_state_idx"
           )

    create index(:flow_node_instances, [:state],
             name: "flow_node_instances_state_active_idx",
             where: "state = 'active'"
           )

    create index(:flow_node_instances, [:process_instance_id, :lane_name],
             name: "flow_node_instances_process_instance_id_lane_idx"
           )

    create index(:flow_node_instances, [:process_instance_id],
             name: "flow_node_instances_process_instance_id_idx"
           )

    create index(:flow_node_instances, [:multi_instance_id],
             name: "flow_node_instances_multi_instance_id_idx",
             where: "multi_instance_id IS NOT NULL"
           )

    # ---------------------------------------------------------------
    # 4. Audit tables
    # ---------------------------------------------------------------

    partitioned? = partition_interval() != :off

    if partitioned? do
      execute("""
      CREATE TABLE process_instance_events (
        id UUID NOT NULL DEFAULT uuid_generate_v7(),
        process_instance_id UUID,
        flow_node_instance_id UUID,
        event_type TEXT NOT NULL,
        severity TEXT NOT NULL DEFAULT 'info',
        occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        payload JSONB,
        PRIMARY KEY (id, occurred_at)
      ) PARTITION BY RANGE (occurred_at)
      """)
    else
      execute("""
      CREATE TABLE process_instance_events (
        id UUID NOT NULL DEFAULT uuid_generate_v7() PRIMARY KEY,
        process_instance_id UUID,
        flow_node_instance_id UUID,
        event_type TEXT NOT NULL,
        severity TEXT NOT NULL DEFAULT 'info',
        occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        payload JSONB
      )
      """)

      create index(:process_instance_events, [:occurred_at],
               name: "process_instance_events_occurred_at_idx"
             )
    end

    create index(:process_instance_events, [:process_instance_id],
             name: "process_instance_events_process_instance_id_idx"
           )

    create index(:process_instance_events, [:event_type],
             name: "process_instance_events_event_type_idx"
           )

    create table(:data_objects, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :process_instance_id, :uuid, null: false
      add :data_object_id, :text, null: false
      add :flow_node_instance_id, :uuid, null: false
      add :value, :map
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:data_objects, [:process_instance_id],
             name: "data_objects_process_instance_id_idx"
           )

    create unique_index(:data_objects, [:process_instance_id, :data_object_id],
             name: "data_objects_process_instance_data_object_unique_idx"
           )

    if partitioned? do
      execute("""
      CREATE TABLE data_object_writes (
        id UUID NOT NULL DEFAULT uuid_generate_v7(),
        process_instance_id UUID NOT NULL,
        data_object_id TEXT NOT NULL,
        flow_node_instance_id UUID NOT NULL,
        value JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (id, created_at)
      ) PARTITION BY RANGE (created_at)
      """)
    else
      execute("""
      CREATE TABLE data_object_writes (
        id UUID NOT NULL DEFAULT uuid_generate_v7() PRIMARY KEY,
        process_instance_id UUID NOT NULL,
        data_object_id TEXT NOT NULL,
        flow_node_instance_id UUID NOT NULL,
        value JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
      """)

      create index(:data_object_writes, [:created_at],
               name: "data_object_writes_created_at_idx"
             )
    end

    create index(:data_object_writes, [:process_instance_id],
             name: "data_object_writes_process_instance_id_idx"
           )

    # ---------------------------------------------------------------
    # 4b. Message audit tables
    # ---------------------------------------------------------------

    if partitioned? do
      execute("""
      CREATE TABLE messages (
        id UUID NOT NULL DEFAULT uuid_generate_v7(),
        message_name TEXT NOT NULL,
        payload JSONB,
        correlation_value TEXT,
        origin JSONB,
        published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        correlations JSONB NOT NULL DEFAULT '[]'::jsonb,
        started_process_instance_ids TEXT[] NOT NULL DEFAULT '{}',
        PRIMARY KEY (id, published_at)
      ) PARTITION BY RANGE (published_at)
      """)
    else
      execute("""
      CREATE TABLE messages (
        id UUID NOT NULL DEFAULT uuid_generate_v7() PRIMARY KEY,
        message_name TEXT NOT NULL,
        payload JSONB,
        correlation_value TEXT,
        origin JSONB,
        published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        correlations JSONB NOT NULL DEFAULT '[]'::jsonb,
        started_process_instance_ids TEXT[] NOT NULL DEFAULT '{}'
      )
      """)

      create index(:messages, [:published_at], name: "messages_published_at_idx")
    end

    create index(:messages, [:message_name, :published_at],
             name: "messages_message_name_published_at_idx"
           )

    create index(:messages, [:message_name, :correlation_value],
             name: "messages_message_name_correlation_value_idx"
           )

    if partitioned? do
      execute("""
      CREATE TABLE pending_messages (
        id UUID NOT NULL DEFAULT uuid_generate_v7(),
        message_id UUID NOT NULL,
        message_name TEXT NOT NULL,
        correlation_value TEXT,
        payload JSONB,
        published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        expires_at TIMESTAMPTZ NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        delivered_at TIMESTAMPTZ,
        expired_at TIMESTAMPTZ,
        PRIMARY KEY (id, published_at)
      ) PARTITION BY RANGE (published_at)
      """)
    else
      execute("""
      CREATE TABLE pending_messages (
        id UUID NOT NULL DEFAULT uuid_generate_v7() PRIMARY KEY,
        message_id UUID NOT NULL,
        message_name TEXT NOT NULL,
        correlation_value TEXT,
        payload JSONB,
        published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        expires_at TIMESTAMPTZ NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        delivered_at TIMESTAMPTZ,
        expired_at TIMESTAMPTZ
      )
      """)

      create index(:pending_messages, [:published_at], name: "pending_messages_published_at_idx")
    end

    create index(:pending_messages, [:message_name, :correlation_value],
             name: "pending_messages_name_correlation_pending_idx",
             where: "state = 'pending'"
           )

    create index(:pending_messages, [:expires_at],
             name: "pending_messages_expires_at_pending_idx",
             where: "state = 'pending'"
           )

    # ---------------------------------------------------------------
    # 4c. Signal audit tables
    # ---------------------------------------------------------------

    if partitioned? do
      execute("""
      CREATE TABLE signals (
        id UUID NOT NULL DEFAULT uuid_generate_v7(),
        signal_name TEXT NOT NULL,
        origin JSONB,
        published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        deliveries JSONB NOT NULL DEFAULT '[]'::jsonb,
        started_process_instance_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
        PRIMARY KEY (id, published_at)
      ) PARTITION BY RANGE (published_at)
      """)
    else
      execute("""
      CREATE TABLE signals (
        id UUID NOT NULL DEFAULT uuid_generate_v7() PRIMARY KEY,
        signal_name TEXT NOT NULL,
        origin JSONB,
        published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        deliveries JSONB NOT NULL DEFAULT '[]'::jsonb,
        started_process_instance_ids JSONB NOT NULL DEFAULT '[]'::jsonb
      )
      """)

      create index(:signals, [:published_at], name: "signals_published_at_idx")
    end

    create index(:signals, [:signal_name, :published_at],
             name: "signals_signal_name_published_at_idx"
           )

    create index(:signals, [:signal_name],
             name: "signals_signal_name_idx"
           )

    if partitioned? do
      execute("""
      CREATE TABLE pending_signals (
        id UUID NOT NULL DEFAULT uuid_generate_v7(),
        signal_id UUID NOT NULL,
        signal_name TEXT NOT NULL,
        published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        expires_at TIMESTAMPTZ NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        delivered_at TIMESTAMPTZ,
        expired_at TIMESTAMPTZ,
        PRIMARY KEY (id, published_at)
      ) PARTITION BY RANGE (published_at)
      """)
    else
      execute("""
      CREATE TABLE pending_signals (
        id UUID NOT NULL DEFAULT uuid_generate_v7() PRIMARY KEY,
        signal_id UUID NOT NULL,
        signal_name TEXT NOT NULL,
        published_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        expires_at TIMESTAMPTZ NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        delivered_at TIMESTAMPTZ,
        expired_at TIMESTAMPTZ
      )
      """)

      create index(:pending_signals, [:published_at], name: "pending_signals_published_at_idx")
    end

    create index(:pending_signals, [:signal_name],
             name: "pending_signals_signal_name_pending_idx",
             where: "state = 'pending'"
           )

    create index(:pending_signals, [:expires_at],
             name: "pending_signals_expires_at_pending_idx",
             where: "state = 'pending'"
           )

    # ---------------------------------------------------------------
    # 5. JSONB compression
    # ---------------------------------------------------------------

    compression = jsonb_compression()

    for {table, column} <- @lz4_columns do
      execute("ALTER TABLE #{table} ALTER COLUMN #{column} SET COMPRESSION #{compression}")
    end

    for {table, column} <- @lz4_columns_partitioned do
      execute("ALTER TABLE #{table} ALTER COLUMN #{column} SET COMPRESSION #{compression}")
    end

    # ---------------------------------------------------------------
    # 6. DMN catalog tables
    # ---------------------------------------------------------------

    create table(:decision_definitions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :decision_definition_id, :text, null: false
      add :name, :text
      add :enabled, :boolean, null: false, default: true
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:decision_definitions, [:decision_definition_id],
             name: "decision_definitions_decision_definition_id_unique_idx"
           )

    create table(:decision_versions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :decision_definition_id,
        references(:decision_definitions, type: :uuid, on_delete: :restrict),
        null: false

      add :version, :text, null: false
      add :dmn_xml, :text, null: false
      add :deployer, :map
      add :deployed_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :deleted, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime_usec
      add :deleted_by, :map
    end

    create unique_index(:decision_versions, [:decision_definition_id, :version],
             name: "decision_versions_unique_definition_version_index",
             where: "deleted = false"
           )

    create index(:decision_versions, [:decision_definition_id],
             name: "decision_versions_decision_definition_id_idx"
           )

    create constraint(:decision_versions, :decision_versions_deleted_consistency,
             check: """
               (deleted = false AND deleted_at IS NULL AND deleted_by IS NULL)
             OR (deleted = true AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL)
             """
           )
  end

  defp jsonb_compression do
    retention_config = Application.get_env(:peripheral_persistence, :retention, [])
    Keyword.get(retention_config, :jsonb_compression, "lz4")
  end

  defp partition_interval do
    Application.get_env(:peripheral_persistence, :partition_interval, :quarterly)
  end

  def down do
    # ---------------------------------------------------------------
    # 6. DMN catalog tables (reverse order)
    # ---------------------------------------------------------------

    drop_if_exists constraint(:decision_versions, :decision_versions_deleted_consistency)

    drop_if_exists index(:decision_versions, [:decision_definition_id],
                     name: "decision_versions_decision_definition_id_idx"
                   )

    drop_if_exists unique_index(:decision_versions, [:decision_definition_id, :version],
                     name: "decision_versions_unique_definition_version_index"
                   )

    drop table(:decision_versions)

    drop_if_exists unique_index(:decision_definitions, [:decision_definition_id],
                     name: "decision_definitions_decision_definition_id_unique_idx"
                   )

    drop table(:decision_definitions)

    # ---------------------------------------------------------------
    # Audit / data tables
    # ---------------------------------------------------------------

    # Pending signals
    drop_if_exists index(:pending_signals, [:expires_at],
                     name: "pending_signals_expires_at_pending_idx"
                   )

    drop_if_exists index(:pending_signals, [:signal_name],
                     name: "pending_signals_signal_name_pending_idx"
                   )

    drop_if_exists index(:pending_signals, [:published_at],
                     name: "pending_signals_published_at_idx"
                   )

    execute("DROP TABLE IF EXISTS pending_signals CASCADE")

    # Signals
    drop_if_exists index(:signals, [:signal_name],
                     name: "signals_signal_name_idx"
                   )

    drop_if_exists index(:signals, [:signal_name, :published_at],
                     name: "signals_signal_name_published_at_idx"
                   )

    drop_if_exists index(:signals, [:published_at], name: "signals_published_at_idx")

    execute("DROP TABLE IF EXISTS signals CASCADE")

    # Pending messages
    drop_if_exists index(:pending_messages, [:expires_at],
                     name: "pending_messages_expires_at_pending_idx"
                   )

    drop_if_exists index(:pending_messages, [:message_name, :correlation_value],
                     name: "pending_messages_name_correlation_pending_idx"
                   )

    drop_if_exists index(:pending_messages, [:published_at],
                     name: "pending_messages_published_at_idx"
                   )

    execute("DROP TABLE IF EXISTS pending_messages CASCADE")

    # Messages
    drop_if_exists index(:messages, [:message_name, :correlation_value],
                     name: "messages_message_name_correlation_value_idx"
                   )

    drop_if_exists index(:messages, [:message_name, :published_at],
                     name: "messages_message_name_published_at_idx"
                   )

    drop_if_exists index(:messages, [:published_at], name: "messages_published_at_idx")

    execute("DROP TABLE IF EXISTS messages CASCADE")

    drop_if_exists index(:data_object_writes, [:process_instance_id],
                     name: "data_object_writes_process_instance_id_idx"
                   )

    drop_if_exists index(:data_object_writes, [:created_at],
                     name: "data_object_writes_created_at_idx"
                   )

    execute("DROP TABLE IF EXISTS data_object_writes CASCADE")

    drop_if_exists unique_index(:data_objects, [:process_instance_id, :data_object_id],
                     name: "data_objects_process_instance_data_object_unique_idx"
                   )

    drop_if_exists index(:data_objects, [:process_instance_id],
                     name: "data_objects_process_instance_id_idx"
                   )

    drop table(:data_objects)

    drop_if_exists index(:process_instance_events, [:event_type],
                     name: "process_instance_events_event_type_idx"
                   )

    drop_if_exists index(:process_instance_events, [:process_instance_id],
                     name: "process_instance_events_process_instance_id_idx"
                   )

    drop_if_exists index(:process_instance_events, [:occurred_at],
                     name: "process_instance_events_occurred_at_idx"
                   )

    execute("DROP TABLE IF EXISTS process_instance_events CASCADE")

    drop_if_exists constraint(:process_instances, :process_instances_deleted_consistency)

    drop_if_exists index(:flow_node_instances, [:multi_instance_id],
                     name: "flow_node_instances_multi_instance_id_idx"
                   )

    drop_if_exists index(:flow_node_instances, [:process_instance_id],
                     name: "flow_node_instances_process_instance_id_idx"
                   )

    drop_if_exists index(:flow_node_instances, [:process_instance_id, :lane_name],
                     name: "flow_node_instances_process_instance_id_lane_idx"
                   )

    drop_if_exists index(:flow_node_instances, [:state],
                     name: "flow_node_instances_state_active_idx"
                   )

    drop_if_exists index(:flow_node_instances, [:flow_node_type, :state],
                     name: "flow_node_instances_type_state_idx"
                   )

    drop_if_exists constraint(:flow_node_instances, :flow_node_instances_deleted_consistency)

    drop table(:flow_node_instances)

    drop_if_exists unique_index(
                     :gateway_pending_arrivals,
                     [:gateway_flow_node_instance_id, :source_branch_sequence_flow_id],
                     name: "gateway_pending_arrivals_unique_branch_arrival_index"
                   )

    drop_if_exists index(:gateway_pending_arrivals, [:process_instance_id],
                     name: "gateway_pending_arrivals_process_instance_id_idx"
                   )

    drop_if_exists index(:gateway_pending_arrivals, [:gateway_flow_node_instance_id],
                     name: "gateway_pending_arrivals_gateway_flow_node_instance_idx"
                   )

    drop table(:gateway_pending_arrivals)

    drop_if_exists index(:process_instances, [:state],
                     name: "process_instances_state_running_idx"
                   )

    drop_if_exists index(:process_instances, [:process_version_id, :state],
                     name: "process_instances_version_state_idx"
                   )

    drop_if_exists index(:process_instances, [:business_key],
                     name: "process_instances_business_key_idx"
                   )

    drop table(:process_instances)

    drop_if_exists constraint(:timer_start_schedules, :timer_start_schedules_kind_cycle)

    drop_if_exists index(:timer_start_schedules, [:enabled, :next_fire_at],
                     name: "timer_start_schedules_armed_idx"
                   )

    drop_if_exists unique_index(
                     :timer_start_schedules,
                     [:process_version_id, :flow_node_id],
                     name: "timer_start_schedules_version_flow_node_index"
                   )

    drop table(:timer_start_schedules)

    drop_if_exists constraint(:process_versions, :process_versions_deleted_consistency)

    drop_if_exists index(:process_versions, [:process_id],
                     name: "process_versions_process_id_idx"
                   )

    drop_if_exists unique_index(:process_versions, [:process_id, :version],
                     name: "process_versions_unique_process_version_index"
                   )

    drop table(:process_versions)

    drop_if_exists unique_index(:processes, [:process_model_id],
                     name: "processes_process_model_id_unique_idx"
                   )

    drop table(:processes)

    execute(
      "DROP FUNCTION IF EXISTS uuid_generate_v7(), ash_raise_error(jsonb), ash_raise_error(jsonb, ANYCOMPATIBLE), ash_elixir_and(BOOLEAN, ANYCOMPATIBLE), ash_elixir_and(ANYCOMPATIBLE, ANYCOMPATIBLE), ash_elixir_or(ANYCOMPATIBLE, ANYCOMPATIBLE), ash_elixir_or(BOOLEAN, ANYCOMPATIBLE), ash_trim_whitespace(text[]), ash_required(ANYCOMPATIBLE, jsonb)"
    )
  end
end
