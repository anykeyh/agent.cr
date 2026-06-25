class Agent
  class Config
    getter api_endpoint : String
    getter api_key : String?
    getter model : String
    getter system_prompt : String?
    getter max_tokens : Int32?
    getter temperature : Float64?
    getter read_timeout : Time::Span?
    getter connect_timeout : Time::Span?
    getter max_history : Int32?
    getter auto_execute_tools : Bool

    def initialize(
      @api_key : String? = nil,
      @api_endpoint : String = "https://api.openai.com/v1",
      @model : String = "gpt-4o",
      @system_prompt : String? = nil,
      @max_tokens : Int32? = nil,
      @temperature : Float64? = nil,
      @read_timeout : Time::Span? = nil,
      @connect_timeout : Time::Span? = nil,
      @max_history : Int32? = nil,
      @auto_execute_tools : Bool = true,
    )
    end
  end
end
