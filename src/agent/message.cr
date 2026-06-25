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
      case value.downcase
      when "system"    then System
      when "user"      then User
      when "assistant" then Assistant
      when "tool"      then Tool
      else                  raise ArgumentError.new("Unknown role: '#{value}'")
      end
    end
  end

  # A content part used in multimodal messages (text + images).
  class ContentPart
    getter text : String?
    getter image_url : String?
    getter image_detail : String?

    def initialize(@text : String? = nil, @image_url : String? = nil, @image_detail : String = "auto")
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
  class ToolCall
    getter id : String
    getter name : String
    getter arguments : String # JSON string

    def initialize(@id : String, @name : String, @arguments : String)
    end
  end

  # A message in the conversation.
  class Message
    getter role : Role
    getter content : String?
    getter content_parts : Array(ContentPart)?
    getter tool_calls : Array(ToolCall)?
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
        io << " #{c[0, {c.size, 80}.min].inspect}"
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

  # Token usage metadata from the API.
  class Usage
    getter prompt_tokens : Int32?
    getter completion_tokens : Int32?
    getter total_tokens : Int32?

    def initialize(@prompt_tokens = nil, @completion_tokens = nil, @total_tokens = nil)
    end
  end
end
