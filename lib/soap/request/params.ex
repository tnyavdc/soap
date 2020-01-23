defmodule Soap.Request.Params do
  @moduledoc """
  Documentation for Soap.Request.Options.
  """
  import XmlBuilder, only: [element: 3, document: 1, generate: 2]

  @schema_types %{
    "xmlns:xsd" => "http://www.w3.org/2001/XMLSchema",
    "xmlns:xsi" => "http://www.w3.org/2001/XMLSchema-instance"
  }
  @soap_version_namespaces %{
    "1.1" => "http://schemas.xmlsoap.org/soap/envelope/",
    "1.2" => "http://www.w3.org/2003/05/soap-envelope"
  }
  @date_type_regex "[0-9]{4}-[0-9]{2}-[0-9]{2}"
  @date_time_type_regex "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"

  @doc """
  Parsing parameters map and generate body xml by given soap action name and body params(Map).
  Returns xml-like string.
  """

  # Tanya fork for Purolator: Passing headers in order to make an Authorized request
  @spec build_body(wsdl :: map(), operation :: String.t() | atom(), params :: map(), headers :: map()) :: String.t()
  def build_body(wsdl, operation, params, headers, opts \\ []) do
    complex_type_name = Keyword.get(opts, :complex_type_name) || operation
    complex_type_prefix = Keyword.get(opts, :complex_type_prefix) || ""
    with {:ok, body} <- build_soap_body(wsdl, operation, params, opts),
         {:ok, header} <- build_soap_header(wsdl, operation, headers) do
      [header, body]
      # Tanya form for Purolator: Passing complex_type_name and complex_type prefix since Purolator request body wrapper nodename != operation name
      |> add_envelope_tag_wrapper(wsdl, complex_type_name, complex_type_prefix)
      |> document
      |> generate(format: :none)
      |> String.replace(["\n", "\t"], "")
    else
      {:error, message} -> message
    end
  end

  @spec validate_params(params :: any(), wsdl :: map(), operation :: String.t()) :: any()
  def validate_params(params, _wsdl, _operation) when is_binary(params), do: params

  def validate_params(params, wsdl, operation) do
    errors =
      params
      |> Enum.map(&validate_param(&1, wsdl, operation))

    case Enum.any?(errors) do
      true ->
        {:error, Enum.reject(errors, &is_nil/1)}

      _ ->
        params
    end
  end

  @spec validate_param(param :: tuple(), wsdl :: map(), operation :: String.t()) :: String.t() | nil
  defp validate_param(param, wsdl, operation) do
    {k, _, v} = param

    case val_map = wsdl.validation_types[String.downcase(operation)] do
      nil ->
        nil

      _ ->
        if Map.has_key?(val_map, k) do
          validate_param_attributes(val_map, k, v)
        else
          "Invalid SOAP message:Invalid content was found starting with element '#{k}'. One of {#{
            Enum.join(Map.keys(val_map), ", ")
          }} is expected."
        end
    end
  end

  @spec validate_param_attributes(val_map :: map(), k :: String.t(), v :: String.t()) :: String.t() | nil
  defp validate_param_attributes(val_map, k, v) do
    attributes = val_map[k]
    [_, type] = String.split(attributes.type, ":")

    case Integer.parse(v) do
      {number, ""} -> validate_type(k, number, type)
      _ -> validate_type(k, v, type)
    end
  end

  defp validate_type(_k, v, "string") when is_binary(v), do: nil
  defp validate_type(k, _v, type = "string"), do: type_error_message(k, type)

  defp validate_type(_k, v, "decimal") when is_number(v), do: nil
  defp validate_type(k, _v, type = "decimal"), do: type_error_message(k, type)

  defp validate_type(k, v, "date") when is_binary(v) do
    case Regex.match?(~r/#{@date_type_regex}/, v) do
      true -> nil
      _ -> format_error_message(k, @date_type_regex)
    end
  end

  defp validate_type(k, _v, type = "date"), do: type_error_message(k, type)

  defp validate_type(k, v, "dateTime") when is_binary(v) do
    case Regex.match?(~r/#{@date_time_type_regex}/, v) do
      true -> nil
      _ -> format_error_message(k, @date_time_type_regex)
    end

    nil
  end

  defp validate_type(k, _v, type = "dateTime"), do: type_error_message(k, type)

  # Tanya fork for Purolator: Passing opts with complex_type_name and complex_type_prefix since Purolator request wrapper nodename != operation name
  defp build_soap_body(wsdl, operation, params, opts \\ []) do
    complex_type_name = Keyword.get(opts, :complex_type_name) || operation
    complex_type_prefix = Keyword.get(opts, :complex_type_prefix) || ""
    case params |> construct_xml_request_body |> validate_params(wsdl, operation) do
      {:error, messages} ->
        {:error, messages}

      validated_params ->
        body =
          validated_params
          |> add_action_tag_wrapper(wsdl, complex_type_name, complex_type_prefix)
          |> add_body_tag_wrapper

        {:ok, body}
    end
  end

  defp build_soap_header(wsdl, operation, headers) do
    # Tanya fork for Purolator: Take namespace prefix from passed headers. Soap headers must be prefixed with custom prefix in order for Purolator to accept them, but the
    header_key = headers |> Keyword.keys() |> hd()
    prefix = header_key |> to_string() |> String.split(":") |> hd()
    header_namespace_prefix = if prefix != header_key, do: "#{prefix}:", else: ""
    case headers |> construct_xml_request_header do
      {:error, messages} ->
        {:error, messages}

      validated_params ->
        body =
          validated_params
          |> add_header_part_tag_wrapper(wsdl, operation, header_namespace_prefix)
          |> add_header_tag_wrapper
        {:ok, body}
    end
  end

  defp type_error_message(k, type) do
    "Element #{k} has wrong type. Expects #{type} type."
  end

  defp format_error_message(k, regex) do
    "Element #{k} has wrong format. Expects #{regex} format."
  end

  @spec construct_xml_request_body(params :: map() | list()) :: list()
  defp construct_xml_request_body(params) when is_map(params) or is_list(params) do
    params |> Enum.map(&construct_xml_request_body/1)
  end

  @spec construct_xml_request_body(params :: tuple()) :: tuple()
  defp construct_xml_request_body(params) when is_tuple(params) do
    params
    |> Tuple.to_list()
    |> Enum.map(&construct_xml_request_body/1)
    |> insert_tag_parameters
    |> List.to_tuple()
  end

  @spec construct_xml_request_body(params :: String.t() | atom() | number()) :: String.t()
  defp construct_xml_request_body(params) when is_atom(params) or is_number(params), do: params |> to_string
  defp construct_xml_request_body(params) when is_binary(params), do: params

  @spec construct_xml_request_header(params :: map() | list()) :: list()
  defp construct_xml_request_header(params) when is_map(params) or is_list(params) do
    params |> Enum.map(&construct_xml_request_header/1)
  end

  @spec construct_xml_request_header(params :: tuple()) :: tuple()
  defp construct_xml_request_header(params) when is_tuple(params) do
    params
    |> Tuple.to_list()
    |> Enum.map(&construct_xml_request_header/1)
    |> insert_tag_parameters
    |> List.to_tuple()
  end

  @spec construct_xml_request_header(params :: String.t() | atom() | number()) :: String.t()
  defp construct_xml_request_header(params) when is_atom(params) or is_number(params), do: params |> to_string
  defp construct_xml_request_header(params) when is_binary(params), do: params

  @spec insert_tag_parameters(params :: list()) :: list()
  defp insert_tag_parameters(params) when is_list(params), do: params |> List.insert_at(1, nil)

  @spec add_action_tag_wrapper(list(), map(), String.t(), String.t()) :: list()
  defp add_action_tag_wrapper(body, wsdl, complex_type_name, complex_type_prefix) do
    action_tag_attributes = handle_element_form_default(wsdl[:schema_attributes])

    action_tag =
      wsdl[:complex_types]
      |> get_action_with_namespace(complex_type_name, complex_type_prefix)
      |> prepare_action_tag(complex_type_name)

    [element(action_tag, action_tag_attributes, body)]
  end

  @spec add_header_part_tag_wrapper(list(), map(), String.t(), String.t()) :: list()
  defp add_header_part_tag_wrapper(body, wsdl, operation, namespace_prefix \\ "") do
    action_tag_attributes = handle_element_form_default(wsdl[:schema_attributes])
    case get_header_with_namespace(wsdl, operation) do
      nil ->
        nil

      action_tag ->
        # Tanya fork for Purolator. Header part name not prefixed with custom namespace in Purolator messages but must be prefixed
        [element(namespace_prefix <> action_tag, action_tag_attributes, body)]
    end
  end

  defp handle_element_form_default(%{target_namespace: ns, element_form_default: "qualified"}), do: %{xmlns: ns}
  defp handle_element_form_default(_schema_attributes), do: %{}

  defp prepare_action_tag("", operation), do: operation
  defp prepare_action_tag(action_tag, _operation), do: action_tag

  @spec get_action_with_namespace(complex_types :: list(), complex_type_name :: String.t(), complex_type_prefix :: String.t()) :: String.t()
  # Tanya fork for Purolator. complex_types is an empty array for some requests..
  defp get_action_with_namespace([], complex_type_name, complex_type_prefix), do: complex_type_prefix <> complex_type_name
  defp get_action_with_namespace(complex_types, complex_type_name, _complex_type_prefix) do
    complex_types
    |> Enum.find(fn x -> x[:name] == complex_type_name end)
    |> handle_action_extractor_result(complex_types, complex_type_name)
  end
  @spec get_header_with_namespace(wsdl :: map(), operation :: String.t()) :: String.t()
  defp get_header_with_namespace(wsdl, operation) do
    with %{input: %{header: %{message: message, part: part}}} <-
           Enum.find(wsdl[:operations], &(&1[:name] == operation)),
         %{name: name} <- get_message_part(wsdl, message, part) do
      name
    else
      _ -> nil
    end
  end

  defp get_message_part(wsdl, message, part) do
    # Tanya fork for Purolator. message from Purolator :operations is prefixed with namespace but message name in wsdl :messages is not
    message = message |> String.split(":") |> Enum.at(1)
    wsdl[:messages]
    |> Enum.find(&(&1[:name] == message))
    |> Map.get(:parts)
    |> Enum.find(&(&1[:name] == part))
  end

  defp handle_action_extractor_result(nil, complex_types, complex_type_name) do
    name = Enum.find(complex_types, fn x -> Macro.camelize(x[:name]) == complex_type_name end)
    |> Map.get(:type)
    |> String.split("Container") # Tanya fork for Purolator. Purolator complex_types suffixes type name with "Container" but this nodename is not accepted by Purolator in the request body.
    |> hd()
  end

  defp handle_action_extractor_result(result, _complex_types, _operation), do: result |> Map.get(:type) |> String.split("Container") |> hd()

  @spec get_action_namespace(wsdl :: map(), complex_type_name :: String.t(), complex_type_prefix :: String.t()) :: String.t()
  defp get_action_namespace(wsdl, complex_type_name, complex_type_prefix) do
    wsdl[:complex_types]
    |> get_action_with_namespace(complex_type_name, complex_type_prefix)
    |> String.split(":")
    |> List.first()
  end

  @spec add_body_tag_wrapper(list()) :: list()
  defp add_body_tag_wrapper(body), do: [element(:"#{env_namespace()}:Body", nil, body)]

  @spec add_header_tag_wrapper(list()) :: list()
  defp add_header_tag_wrapper(body), do: [element(:"#{env_namespace()}:Header", nil, body)]

  @spec add_envelope_tag_wrapper(body :: any(), wsdl :: map(), complex_type_name :: String.t(), complex_type_prefix :: String.t()) :: any()
  defp add_envelope_tag_wrapper(body, wsdl, complex_type_name, complex_type_prefix) do
    envelop_attributes =
      @schema_types
      |> Map.merge(build_soap_version_attribute(wsdl))
      |> Map.merge(build_action_attribute(wsdl, complex_type_name, complex_type_prefix))
      |> Map.merge(custom_namespaces())

    [element(:"#{env_namespace()}:Envelope", envelop_attributes, body)]
  end

  @spec build_soap_version_attribute(Map.t()) :: map()
  defp build_soap_version_attribute(wsdl) do
    soap_version = wsdl |> soap_version() |> to_string
    %{"xmlns:#{env_namespace()}" => @soap_version_namespaces[soap_version]}
  end

  @spec build_action_attribute(map(), String.t(), String.t()) :: map()
  defp build_action_attribute(wsdl, complex_type_name, complex_type_prefix) do
    action_attribute_namespace = get_action_namespace(wsdl, complex_type_name, complex_type_prefix)
    action_attribute_value = wsdl[:namespaces][action_attribute_namespace][:value]
    prepare_action_attribute(action_attribute_namespace, action_attribute_value)
  end

  defp prepare_action_attribute(_action_attribute_namespace, nil), do: %{}

  defp prepare_action_attribute(action_attribute_namespace, action_attribute_value) do
    %{"xmlns:#{action_attribute_namespace}" => action_attribute_value}
  end

  defp soap_version(wsdl) do
    Map.get(wsdl, :soap_version, Application.fetch_env!(:soap, :globals)[:version])
  end

  defp env_namespace, do: Application.fetch_env!(:soap, :globals)[:env_namespace] || :env
  defp custom_namespaces, do: Application.fetch_env!(:soap, :globals)[:custom_namespaces] || %{}
end
