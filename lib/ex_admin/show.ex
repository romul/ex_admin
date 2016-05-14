defmodule ExAdmin.Show do
  @moduledoc """
  Override the default show page for an ExAdmin resource.

  By default, ExAdmin renders the show page without any additional
  configuration. It renders each column in the model, except the id,
  inserted_at, and updated_at columns in an attributes table.

  To customize the show page, use the `show` macro.

  ## Examples

      register_resource Survey.Seating do
        show seating do
          attributes_table do
            row :id
            row :name
            row :image, [image: true, height: 100], &(ExAdminDemo.Image.url({&1.image, &1}, :thumb))
          end
          panel "Answers" do
            table_for(seating.answers) do
              column "Question", fn(answer) ->
                "#\{answer.question.name}"
              end
              column "Answer", fn(answer) ->
                "#\{answer.choice.name}"
              end
            end
          end
        end

  """
  import ExAdmin.DslUtils
  import ExAdmin.Helpers

  import Kernel, except: [div: 2]
  use Xain

  defmacro __using__(_) do
    quote do
      import unquote(__MODULE__)
    end
  end

  @doc """
  Customize the show page.

  """
  defmacro show(resource, [do: block]) do
    contents = quote do
      unquote(block)
    end

    quote location: :keep, bind_quoted: [resource: escape(resource), contents: escape(contents)] do
      def show_view(var!(conn), unquote(resource) = var!(resource)) do
        import ExAdmin.Utils
        import ExAdmin.ViewHelpers
        _ = var!(resource)
        #var!(query_options) = []
        markup do
          unquote(contents)
        end
      end
    end
  end

  @doc """
  Display a table of the model's attributes.

  When called with a block, the rows specified in the block will be
  displayed.

  When called without a block, the default attributes table will be
  displayed.
  """
  defmacro attributes_table(name \\ nil, do: block) do
    quote location: :keep do
      var!(rows, ExAdmin.Show) = []
      unquote(block)
      rows = var!(rows, ExAdmin.Show) |> Enum.reverse
      name = unquote(name)
      schema = case name do
        nil ->
          %{rows: rows}
        name ->
          %{name: name, rows: rows}
      end
      ExAdmin.Table.attributes_table var!(conn), var!(resource), schema
    end
  end


  defmacro attributes_table do
    quote location: :keep do
      ExAdmin.Show.default_attributes_table(var!(conn), var!(resource))
    end
  end

  @doc """
  Display a table of a specific model's attributes.

  When called with a block, the rows specified in the block will be
  displayed.

  When called without a block, the default attributes table will be
  displayed.
  """
  defmacro attributes_table_for(resource, do: block) do
    quote location: :keep do
      var!(rows, ExAdmin.Show) = []
      unquote(block)
      rows = var!(rows, ExAdmin.Show) |> Enum.reverse
      resource = unquote(resource)
      schema = %{rows: rows}
      ExAdmin.Table.attributes_table_for var!(conn), resource, schema
    end
  end

  @doc """
  Adds a new panel to the show page.

  The block given must include one of two commands:

  * `table_for` - Displays a table for a `:has_many` association.

  * `contents` - Add HTML to a panel
  """
  defmacro panel(name \\ "", do: block) do
    quote do
      var!(table_for, ExAdmin.Show) = []
      var!(contents, ExAdmin.Show) = []
      unquote(block)
      ExAdmin.Table.panel(var!(conn), %{name: unquote(name),
        table_for: var!(table_for, ExAdmin.Show),
        contents: var!(contents, ExAdmin.Show)})
    end
  end

  @doc """
  Add a table for a `:has_many` association.

  ## Examples

      show account do
        attributes_table do
          row :username
          row :email
          row :contact
        end
        panel "Inventory" do
          table_for account.inventory do
            column "Asset", &__MODULE__.inventory_name/1
            column "PO", &(&1.sales_order.po)
            column :quantity
          end
        end
      end

  """
  defmacro table_for(resources, opts, do: block) do
    block = if Dict.has_key?(opts, :sortable) do
      ensure_sort_handle_column(block)
    else
      block
    end

    quote do
      opts = unquote(opts) |> ExAdmin.Show.prepare_sortable_opts

      var!(columns, ExAdmin.Show) = []
      unquote(block)
      columns = var!(columns, ExAdmin.Show) |> Enum.reverse

      var!(table_for, ExAdmin.Show) = %{resources: unquote(resources), columns: columns, opts: opts}
    end
  end
  defmacro table_for(resources, do: block) do
    quote do
      table_for unquote(resources), [], do: unquote(block)
    end
  end

  defp ensure_sort_handle_column({:__block__, trace, cols} = block) do
    has_sort_handle_column = Enum.any?(cols, fn({ctype, _, _}) -> ctype == :sort_handle_column end)
    if has_sort_handle_column do
      block
    else
      {:__block__, trace, [{:sort_handle_column, [], nil} | cols]}
    end
  end

  def prepare_sortable_opts(opts) do
    case opts[:sortable] do
      [resource: resource, assoc_name: assoc_name] ->
        path = ExAdmin.Utils.get_route_path(resource, :update_positions, [resource.id, assoc_name])
        [
          class: "table sortable",
          "data-sortable-link": path
        ] |> Dict.merge(Dict.drop(opts, [:sortable]))

      _ ->
        opts
    end
  end


  defmacro sortable_table_for(resource, assoc_name, do: block) do
    quote do
      resource = unquote(resource)
      assoc_name = unquote(assoc_name)
      resources = Map.get(resource, assoc_name)
      table_for resources, [sortable: [resource: resource, assoc_name: assoc_name]], do: unquote(block)
    end
  end

  @doc """
  Add a markup block to a form.

  Allows the use of the Xain markup to be used in a panel.

  ## Examples

      show user do
        attributes_table

        panel "Testing" do
          markup_contents do
            div ".my-class" do
              test "Tesing"
            end
          end
        end
  """
  defmacro markup_contents(do: block) do
    quote do
      content = markup :nested do
        unquote(block)
      end
      var!(contents, ExAdmin.Show) = %{contents: content}
    end
  end


  defmacro association_filler(resource, opts) do
    quote do
      resource = unquote(resource)
      opts = unquote(opts)
      path = ExAdmin.Utils.get_route_path(resource, :add, [ExAdmin.Schema.get_id(resource), opts[:assoc_name]])

      hr
      h4(opts[:label] || "Enter new #{opts[:assoc_name]}")
      Xain.form class: "association_filler_form", name: "select_#{opts[:assoc_name]}", method: "post", action: path do
        Xain.input name: "_csrf_token", value: Plug.CSRFProtection.get_csrf_token, type: "hidden"
        Xain.input name: "resource_key", value: opts[:resource_key], type: "hidden"
        Xain.input name: "assoc_key", value: opts[:assoc_key], type: "hidden"

        Xain.select class: "association_filler", multiple: "multiple", name: "selected_ids[]" do
          option ""
        end
        Xain.input value: "Save", type: "submit", class: "btn btn-primary", style: "margin-left: 1em;"
      end

      associations_path = ExAdmin.Utils.get_route_path(resource, :show, ExAdmin.Schema.get_id(resource)) <> "/#{opts[:assoc_name]}"
      script type: "text/javascript" do
        text """
        $(document).ready(function() {
          ExAdmin.association_filler_opts.ajax.url = "#{associations_path}";
          $(".association_filler").select2(ExAdmin.association_filler_opts);
        });
        """
      end
    end
  end


  @doc false
  def default_show_view(conn, resource) do
    markup do
      default_attributes_table conn, resource
    end
  end

  @doc false
  def default_attributes_table(conn, resource) do
    [_, res | _] = conn.path_info
    case ExAdmin.get_registered_by_controller_route(res) do
      nil ->
        throw :invalid_route
      %{__struct__: _} = defn ->
        columns = defn.resource_model.__schema__(:fields)
        |> Enum.filter(&(not &1 in [:id, :inserted_at, :updated_at]))
        |> Enum.map(&({translate_field(defn, &1), %{}}))
        |> Enum.filter(&(not is_nil(&1)))
        ExAdmin.Table.attributes_table conn, resource, %{rows: columns}
    end
  end
end
