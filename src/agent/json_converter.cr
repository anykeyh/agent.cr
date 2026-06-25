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
      if value.is_a?(JSON::Any)
        value
      elsif value.is_a?(Hash)
        h = {} of String => JSON::Any
        value.each { |k, v| h[k.to_s] = convert(v) }
        JSON::Any.new(h)
      elsif value.is_a?(NamedTuple)
        h = {} of String => JSON::Any
        value.each { |k, v| h[k.to_s] = convert(v) }
        JSON::Any.new(h)
      elsif value.is_a?(Array)
        JSON::Any.new(value.map { |v| convert(v) })
      elsif value.is_a?(String)
        JSON::Any.new(value)
      elsif value.is_a?(Bool)
        JSON::Any.new(value)
      elsif value.is_a?(Int)
        JSON::Any.new(value.to_i64)
      elsif value.is_a?(Float64)
        JSON::Any.new(value)
      elsif value.is_a?(Float32)
        JSON::Any.new(value.to_f64)
      elsif value.nil?
        JSON::Any.new(value)
      else
        raise ArgumentError.new("JSONConverter cannot handle #{value.class}: #{value.inspect}")
      end
    end
  end
end
