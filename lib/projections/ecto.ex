defmodule Commanded.Projections.Ecto do
  @moduledoc """
  Read model projections for [Commanded](https://hex.pm/packages/commanded) using Ecto.

  Example usage:

      defmodule Projector do
        use Commanded.Projections.Ecto,
          name: "my-projection",
          repo: MyRepo,
          schema_prefix: "my-prefix",
          timeout: :infinity

        project %Event{}, _metadata do
          Ecto.Multi.insert(multi, :my_projection, %MyProjection{...})
        end

        project %AnotherEvent{} do
          Ecto.Multi.insert(multi, :my_projection, %MyProjection{...})
        end
      end

  """

  defmacro __using__(opts) do
    opts = opts || []

    quote location: :keep do
      @opts unquote(opts)
      @repo @opts[:repo] ||
            Application.get_env(:commanded_ecto_projections, :repo) ||
            raise "Commanded Ecto projections expects :repo to be configured in environment"
      @projection_name @opts[:name] || raise "#{inspect __MODULE__} expects :name to be given"
      @timeout @opts[:timeout] || :infinity

      unquote __include_projection_version_schema__(opts[:schema_prefix])

      use Ecto.Schema
      use Commanded.Event.Handler, name: @projection_name

      import Ecto.Changeset
      import Ecto.Query
      import unquote(__MODULE__)

      def update_projection(event, %{event_number: event_number} = metadata, multi_fn) do
        multi =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:verify_projection_version, fn _ ->
            version = case @repo.get(ProjectionVersion, @projection_name) do
              nil -> @repo.insert!(%ProjectionVersion{projection_name: @projection_name, last_seen_event_number: 0})
              version -> version
            end

            if version.last_seen_event_number == nil || version.last_seen_event_number < event_number do
              {:ok, %{version: version}}
            else
              {:error, :already_seen_event}
            end
          end)
          |> Ecto.Multi.update(:projection_version, ProjectionVersion.changeset(%ProjectionVersion{projection_name: @projection_name}, %{last_seen_event_number: event_number}))

        multi = apply(multi_fn, [multi])

        case @repo.transaction(multi, timeout: @timeout, pool_timeout: @timeout) do
          {:ok, changes} -> after_update(event, metadata, changes)
          {:error, :verify_projection_version, :already_seen_event, _changes} -> :ok
          {:error, stage, reason, _changes} -> {:error, reason}
        end
      end

      def after_update(_event, _metadata, _changes), do: :ok

      defoverridable [
        after_update: 3,
      ]
    end
  end

  defp __include_projection_version_schema__(prefix) do
    prefix = prefix || Application.get_env(:commanded_ecto_projections, :schema_prefix)

    quote do
      defmodule ProjectionVersion do
        @moduledoc false

        use Ecto.Schema

        import Ecto.Changeset

        @primary_key {:projection_name, :string, []}
        @schema_prefix unquote(prefix)

        schema "projection_versions" do
          field :last_seen_event_number, :integer

          timestamps()
        end

        @required_fields ~w(last_seen_event_number)

        def changeset(model, params \\ :empty) do
          cast(model, params, @required_fields)
        end
      end
    end
  end

  defmacro project(event, metadata, do: block) do
    quote do
      def handle(unquote(event) = event, unquote(metadata) = metadata) do
        update_projection(event, metadata, fn var!(multi) ->
          unquote(block)
        end)
      end
    end
  end

  defmacro project(event, do: block) do
    quote do
      def handle(unquote(event) = event, metadata) do
        update_projection(event, metadata, fn var!(multi) ->
          unquote(block)
        end)
      end
    end
  end
end
