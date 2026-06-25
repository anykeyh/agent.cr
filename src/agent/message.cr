require "json"

class Agent
  # A content part used in multimodal messages (text + images).
  class ContentPart
    getter text : String?
    getter image_url : String?
    getter image_detail : String?

    def initialize(@text : String? = nil, @image_url : String? = nil, @image_detail : String = "auto")
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
    include JSON::Serializable

    property id : String
    property name : String
    property arguments : String # JSON string

    def initialize(@id : String, @name : String, @arguments : String)
    end
  end

  # A message in the conversation.
  class Message
    getter role : String
    getter content : String?
    getter content_parts : Array(ContentPart)?
    getter tool_calls : Array(ToolCall)?
    getter tool_call_id : String?
    getter name : String?
    getter reasoning : String?

    def initialize(
      @role : String,
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

    # :nodoc:
    def to_request_body : Hash(String, JSON::Any)
      body = {"role" => JSON::Any.new(@role)}

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
    include JSON::Serializable

    property prompt_tokens : Int32?
    property completion_tokens : Int32?
    property total_tokens : Int32?

    def initialize(@prompt_tokens = nil, @completion_tokens = nil, @total_tokens = nil)
    end
  end
end
