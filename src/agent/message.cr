require "json"

class Agent
  # Valid roles for messages as per the OpenAI API.
  enum Role
    System
    User
    Assistant
    Tool

    # Serialise to JSON as lowercase string.
    def to_s : String
      case self
      in System    then "system"
      in User      then "user"
      in Assistant then "assistant"
      in Tool      then "tool"
      end
    end

    # Parse from a lowercase string. Raises ArgumentError for invalid input.
    def self.parse(value : String) : Role
      case value.strip.downcase
      when "system"    then System
      when "user"      then User
      when "assistant" then Assistant
      when "tool"      then Tool
      else                  raise ArgumentError.new("Unknown role: '#{value}'")
      end
    end
  end

  # JSON converter for Role serialization with JSON::Serializable.
  module RoleConverter
    extend self

    def to_json(value : Role, json : JSON::Builder) : Nil
      json.string(value.to_s)
    end

    def from_json(value : JSON::PullParser) : Role
      Role.parse(value.read_string)
    end
  end

  # A content part used in multimodal messages (text + images).
  @[JSON::Serializable::Options(emit_nulls: true)]
  class ContentPart
    include JSON::Serializable

    getter text : String?
    getter image_url : String?
    getter image_detail : String

    def initialize(@text : String? = nil, @image_url : String? = nil, @image_detail : String? = "auto")
      if @text.nil? && @image_url.nil?
        raise ArgumentError.new("ContentPart must have either text or image_url")
      end
    end

    # :nodoc:
    def to_json_body : Hash(String, JSON::Any)
      if url = @image_url
        {
          "type"      => JSON::Any.new("image_url"),
          "image_url" => JSON::Any.new({
            "url"    => JSON::Any.new(url),
            "detail" => JSON::Any.new(@image_detail),
          }.to_h),
        }
      else
        {
          "type" => JSON::Any.new("text"),
          "text" => JSON::Any.new(@text || ""),
        }
      end
    end
  end

  # Represents a tool call from the assistant.
  @[JSON::Serializable::Options(emit_nulls: true)]
  class ToolCall
    include JSON::Serializable

    getter id : String
    getter name : String
    getter arguments : String

    def initialize(@id : String, @name : String, @arguments : String)
    end

    # :nodoc:
    def ==(other : self) : Bool
      @id == other.id && @name == other.name && @arguments == other.arguments
    end

    def ==(other) : Bool
      false
    end
  end

  # Token usage metadata from the API.
  @[JSON::Serializable::Options(emit_nulls: true)]
  class Usage
    include JSON::Serializable

    getter prompt_tokens : Int32?
    getter completion_tokens : Int32?
    getter total_tokens : Int32?

    def initialize(@prompt_tokens = nil, @completion_tokens = nil, @total_tokens = nil)
    end
  end

  # A message in the conversation.
  @[JSON::Serializable::Options(emit_nulls: true)]
  class Message
    include JSON::Serializable

    @[JSON::Field(key: "role", converter: Agent::RoleConverter)]
    getter role : Role
    getter content : String?
    @[JSON::Field(key: "content_parts")]
    getter content_parts : Array(ContentPart)?
    @[JSON::Field(key: "tool_calls")]
    getter tool_calls : Array(ToolCall)?
    @[JSON::Field(key: "tool_call_id")]
    getter tool_call_id : String?
    getter name : String?
    getter reasoning : String?

    def initialize(
      @role : Role,
      @content : String? = nil,
      @content_parts : Array(ContentPart)? = nil,
      @tool_calls : Array(ToolCall)? = nil,
      @tool_call_id : String? = nil,
      @name : String? = nil,
      @reasoning : String? = nil,
    )
    end

    def has_tool_calls? : Bool
      tc = @tool_calls
      !tc.nil? && !tc.empty?
    end

    def ==(other : self) : Bool
      @role == other.role && @content == other.content &&
        @content_parts == other.content_parts &&
        @tool_call_id == other.tool_call_id && @name == other.name &&
        @tool_calls == other.tool_calls && @reasoning == other.reasoning
    end

    def ==(other) : Bool
      false
    end

    def inspect(io : IO) : Nil
      io << "#<Message:"
      io << @role.to_s
      if c = @content
        io << " #{c[0, Math.min(c.size, 80)].inspect}"
      elsif @content_parts
        io << " (multimodal)"
      end
      if tc = @tool_calls
        io << " tool_calls=#{tc.size}"
      end
      if @reasoning
        io << " (reasoning)"
      end
      io << ">"
    end

    # :nodoc:
    def to_request_body : Hash(String, JSON::Any)
      body = {"role" => JSON::Any.new(@role.to_s)}

      # Build content
      if parts = @content_parts
        body["content"] = JSON::Any.new(parts.map(&.to_json_body).map { |h| JSON::Any.new(h) })
      elsif text = @content
        body["content"] = JSON::Any.new(text)
      elsif @role == Role::Tool
        body["content"] = JSON::Any.new("")
      else
        body["content"] = JSON::Any.new(nil)
      end

      body["tool_call_id"] = JSON::Any.new(@tool_call_id) if @tool_call_id
      body["name"] = JSON::Any.new(@name) if @name

      if tcs = @tool_calls
        body["tool_calls"] = JSON::Any.new(tcs.map do |tc|
          JSON::Any.new({
            "id"       => JSON::Any.new(tc.id),
            "type"     => JSON::Any.new("function"),
            "function" => JSON::Any.new({
              "name"      => JSON::Any.new(tc.name),
              "arguments" => JSON::Any.new(tc.arguments),
            }),
          })
        end)
      end

      body
    end
  end
end
