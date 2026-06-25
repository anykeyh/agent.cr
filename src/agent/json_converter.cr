class Agent
  # Utility for converting Crystal types into `Hash(String, JSON::Any)`
  # for tool parameter definitions — no more `JSON::Any.new(...)` boilerplate.
  #
  # ```
  # params = Agent::JSONConverter.from({
  #   type:       "object",
  #   properties: {
  #     city: {type: "string", description: "The city name"},
  #   },
  #   required: ["city"],
  # })
  #
  # agent.register_tool("get_weather", "Get weather for a city", parameters: params) do |args|
  #   # ...
  # end
  # ```
  # Backward-compatible alias — maintained for existing tool definitions.
  # Prefer `JSONConverter` for new code.
  JSONSchema = JSONConverter

  module JSONConverter
    extend self

    # Convert a value to `Hash(String, JSON::Any)` recursively.
    # Accepts nested `NamedTuple`s, `Hash`es, `Array`s, and scalar types.
    def from(value) : Hash(String, JSON::Any)
      result = convert(value)
      result.as_h
    end

    # :nodoc:
    def convert(value) : JSON::Any
      case value
      when JSON::Any then value
      when Hash, NamedTuple
        h = {} of String => JSON::Any
        value.each { |k, v| h[k.to_s] = convert(v) }
        JSON::Any.new(h)
      when Array
        JSON::Any.new(value.map { |v| convert(v) })
      when String  then JSON::Any.new(value)
      when Bool    then JSON::Any.new(value)
      when Int     then JSON::Any.new(value.to_i64)
      when Float64 then JSON::Any.new(value)
      when Float32 then JSON::Any.new(value.to_f64)
      when Nil     then JSON::Any.new(value)
      else
        raise ArgumentError.new("JSONConverter cannot handle #{value.class}: #{value.inspect}")
      end
    end
  end
end
