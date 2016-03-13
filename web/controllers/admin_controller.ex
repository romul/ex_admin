defmodule ExAdmin.AdminController do
  @moduledoc false
  use ExAdmin.Web, :controller

  plug :set_layout
  
  def action(%{private: %{phoenix_action: action}} = conn, _options) do
    handle_action(conn, action, conn.params["resource"])
  end

  defp handle_action(conn, action, nil) do
    ExAdmin.get_all_registered
    |> Enum.sort(&(elem(&1,1).menu[:priority] < elem(&2,1).menu[:priority]))
    |> hd
    |> case do
      {_, %{controller_route: resource}} -> 
        conn = scrub_params(conn, resource, action)
        params = filter_params(conn.params)
        conn
        |> struct(path_info: conn.path_info ++ [resource])
        |> struct(params: Map.put(conn.params, "resource", resource)) 
        |> handle_action(action, resource)
      _other -> 
        throw :invalid_route
    end
  end
  defp handle_action(conn, action, resource) do
    conn = scrub_params(conn, resource, action)
    params = filter_params(conn.params)
    case get_registered_by_controller_route(resource) do
      nil -> 
        throw :invalid_route
      %{__struct__: _} = defn -> 
        conn
        |> handle_plugs(action, defn)
        |> handle_before_filter(action, defn, params)
        |> handle_custom_actions(action, defn, params)
      _ -> 
        apply(__MODULE__, action, [conn, params])
    end
  end

  defp scrub_params(conn, required_key, action) when action in [:create, :update] do
    if conn.params[required_key] do
      Phoenix.Controller.scrub_params conn, required_key   
    else
      conn
    end
  end
  defp scrub_params(conn, _required_key, _action), do: conn

  def handle_custom_actions({conn, params}, action, defn, _) do
    handle_custom_actions(conn, action, defn, params)
  end
  def handle_custom_actions(conn, action, defn, params) do
    %{member_actions: member_actions, collection_actions: collection_actions} = defn
    cond do
      member_action = Keyword.get(member_actions, action) -> 
        member_action.(conn, params)
      collection_action = Keyword.get(collection_actions, action) -> 
        collection_action.(conn, params)
      true -> 
        apply(__MODULE__, action, [conn, params])
    end
  end

  def handle_before_filter(conn, action, defn, params) do
    case defn.controller_filters[:before_filter] do
      nil -> 
        conn
      {name, opts} -> 
        filter = cond do
          opts[:only] -> 
            if action in opts[:only], do: true, else: false
          opts[:except] -> 
            if not action in opts[:except], do: true, else: false
          true -> true
        end
        if filter, do: apply(defn.__struct__, name, [conn, params]), else: conn
    end
  end

  defp handle_plugs(conn, :nested, _defn), do: conn
  defp handle_plugs(conn, _action, defn) do
    case Application.get_env(:ex_admin, :plug, []) do
      list when is_list(list) -> list
      item -> [{item, []}]
    end
    |> Keyword.merge(defn.plugs)
    |> Enum.reduce(conn, fn({name, opts}, conn) -> 
      apply(name, :call, [conn, opts]) 
    end)
    |> authorized?
  end

  defp authorized?(%{assigns: %{authorized: true}} = conn), do: conn
  defp authorized?(%{assigns: %{authorized: false}}) do 
    throw :unauthorized
  end
  defp authorized?(conn), do: conn

  defp set_layout(conn, _) do
    put_layout(conn, "admin.html")
  end

  def index(conn, params) do
    defn = get_registered_by_controller_route(params[:resource])
    contents = case defn do
      nil -> 
        throw :invalid_route
      %{type: :page} = defn -> 
        defn.__struct__ 
        |> apply(:page_view, [conn])
      defn -> 
        model = defn.__struct__ 

        page = case conn.assigns[:page] do
          nil -> 
            model.run_query(repo, :index, params |> Map.to_list)
          page -> 
            page
        end
        if function_exported? model, :index_view, 2 do
          apply(model, :index_view, [conn, page])
        else
          ExAdmin.Index.default_index_view conn, page
        end
    end
    conn
    |> render("admin.html", html: contents, defn: defn, resource: nil,
      filters: (if false in defn.index_filters, do: false, else: defn.index_filters))
  end

  def show(conn, params) do

    {contents, resource} = case get_registered_by_controller_route(params[:resource]) do
      nil -> 
        throw :invalid_route
      defn -> 
        model = defn.__struct__ 

        resource = unless Application.get_all_env(:auth_ex) == [] do
          resource_name = AuthEx.Utils.resource_name conn, model: defn.resource_model
          case conn.assigns[resource_name] do
            nil -> 
              model.run_query(repo, :show, params[:id])
            res -> 
              res
          end
        else
          model.run_query(repo, :show, params[:id])
        end

        if function_exported? model, :show_view, 2 do
          {apply(model, :show_view, [conn, resource]), resource}
        else
          {ExAdmin.Show.default_show_view(conn, resource), resource}
        end
    end
    render conn, "admin.html", html: contents, resource: resource, filters: nil
  end

  def edit(conn, params) do
    {contents, resource} = case get_registered_by_controller_route(params[:resource]) do
      nil -> 
        throw :invalid_route
      defn -> 
        model = defn.__struct__ 
        resource = model.run_query(repo, :edit, params[:id])
        if function_exported? model, :form_view, 3 do
          {apply(model, :form_view, [conn, resource, params]), resource}
        else
          {ExAdmin.Form.default_form_view(conn, resource, params), resource}
        end
    end
    render conn, "admin.html", html: contents, resource: resource, filters: nil
  end

  def new(conn, params) do
    {contents, resource} = case get_registered_by_controller_route(params[:resource]) do
      nil -> 
        throw :invalid_route
      defn -> 
        model = defn.__struct__ 
        resource = model.__struct__.resource_model.__struct__
        {do_form_view(model, conn, resource, params), resource}
    end
    render conn, "admin.html", html: contents, resource: resource, filters: nil
  end

  defp do_form_view(model, conn, resource, params) do
    if function_exported? model, :form_view, 3 do
      apply(model, :form_view, [conn, resource, params])
    else
      ExAdmin.Form.default_form_view conn, resource, params
    end
  end

  def create(conn, params) do
    case get_registered_by_controller_route(params[:resource]) do
      nil -> 
        throw :invalid_route
      defn -> 
        model = defn.__struct__ 
        resource = model.__struct__.resource_model.__struct__
        resource_model = model.__struct__.resource_model 
        |> base_name |> String.downcase |> String.to_atom
        changeset_fn = Keyword.get(defn.changesets, :create, &resource.__struct__.changeset/2)
        changeset = ExAdmin.Repo.changeset(changeset_fn, resource, params[resource_model])

        if changeset.valid? do
          resource = ExAdmin.Repo.insert(changeset) 
          put_flash(conn, :notice, "#{base_name model} was successfully created.")
          |> redirect(to: get_route_path(resource, :show, resource.id))
        else
          conn = put_flash(conn, :inline_error, changeset.errors)
          contents = do_form_view model, conn, changeset.changeset.model, params
          conn |> render("admin.html", html: contents, resource: resource, filters: nil)
        end
    end
  end

  def update(conn, params) do
    case get_registered_by_controller_route(params[:resource]) do
      nil ->
        throw :invalid_route
      defn ->
        model = defn.__struct__
        resource_model = model.__struct__.resource_model
        |> base_name |> String.downcase |> String.to_atom
        resource = model.run_query(repo, :edit, params[:id])
        changeset_fn = Keyword.get(defn.changesets, :update, &resource.__struct__.changeset/2)
        changeset = ExAdmin.Repo.changeset(changeset_fn, resource, params[resource_model])
        if changeset.valid? do
          ExAdmin.Repo.update(changeset)
          put_flash(conn, :notice, "#{base_name model} was successfully updated")
          |> redirect(to: get_route_path(resource, :show, resource.id))
        else
          conn = put_flash(conn, :inline_error, changeset.errors)
          contents = do_form_view model, conn, changeset.changeset.model, params
          conn |> render("admin.html", html: contents, resource: resource, filters: nil)
        end
    end
  end

  def destroy(conn, params) do
    resource_model = 
    case get_registered_by_controller_route(params[:resource]) do
      nil -> 
        throw :invalid_route
      defn -> 
        model = defn.__struct__ 
        resource_model = model.__struct__.resource_model 
        |> base_name |> String.downcase |> String.to_atom

        model.run_query(repo, :edit, params[:id])
        |> ExAdmin.Repo.delete(params[resource_model]) 
        base_name model
    end
    put_flash(conn, :notice, "#{resource_model} was successfully destroyed.")
    |> redirect(to: get_route_path(conn, :index))
  end

  def batch_action(conn, %{batch_action: "destroy"} = params) do
    defn = get_registered_by_controller_route!(params[:resource]) 

    model = defn.__struct__ 
    resource_model = model.__struct__.resource_model 

    ids = params[:collection_selection] 
    count = Enum.count ids
    ids
    |> Enum.map(&(String.to_integer(&1)))
    |> Enum.each(fn(id) -> 
      repo.delete repo.get(resource_model, id)
    end)

    put_flash(conn, :notice, "Successfully destroyed #{count} #{pluralize params[:resource], count}")
    |> redirect(to: get_route_path(conn, :index))
  end

  def csv(conn, params) do
    case get_registered_by_controller_route(params[:resource]) do
      nil -> 
        throw :invalid_route
      defn -> 
        model = defn.__struct__ 

        csv = case model.run_query(repo, :csv) do
          [] -> []
          [resource | resources] -> 
            ExAdmin.View.Adapter.build_csv(resource, resources)
        end

        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header("Content-Disposition", "inline; filename=\"#{params[:resource]}.csv\"")
        |> send_resp(conn.status || 200, csv)
    end
  end

  @nested_key_list for i <- 1..5, do: {String.to_atom("nested#{i}"), String.to_atom("id#{i}")}

  def nested(conn, params) do
    contents = case get_registered_by_controller_route(params[:resource]) do
      nil -> 
        throw :invalid_route
      defn -> 
        model = defn.__struct__ 

        items = apply(model, :get_blocks, [conn, defn.resource_model.__struct__, params])
        block = deep_find(items, String.to_atom(params[:field_name]))
        
        resources = block[:opts][:collection].(conn, defn.resource_model.__struct__)

        contents = apply(model, :ajax_view, [conn, params, resources, block])
        contents
    end
    send_resp(conn, conn.status || 200, "text/javascript", contents)
  end

  def dashboard(conn, _) do
    redirect conn, to: "/admin/contacts"
  end

  def deep_find(items, name) do
    Enum.reduce items, nil, fn(item, acc) -> 
      case item do
        %{inputs: inputs} -> 
          case Enum.find inputs, &(&1[:name] == name) do
            nil -> acc
            found -> found
          end
        _ -> acc
      end
    end
  end
  defp send_resp(conn, default_status, default_content_type, body) do
    conn
    |> ensure_resp_content_type(default_content_type)
    |> Plug.Conn.send_resp(conn.status || default_status, body)
  end

  defp ensure_resp_content_type(%{resp_headers: resp_headers} = conn, content_type) do
    if List.keyfind(resp_headers, "content-type", 0) do
      conn
    else
      content_type = content_type <> "; charset=utf-8"
      %{conn | resp_headers: [{"content-type", content_type}|resp_headers]}
    end
  end

  def repo, do: Application.get_env(:ex_admin, :repo)
end
