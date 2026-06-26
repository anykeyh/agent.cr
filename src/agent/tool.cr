class Agent
  # A tool definition that matches the OpenAI tools API.
  class Tool
    getter function : FunctionDef

    def initialize(@function : FunctionDef)
    end

    class FunctionDef
      getter name : String
      getter description : String?
      getter parameters : Hash(String, JSON::Any)?

      def initialize(@name : String, @description : String? = nil, @parameters : Hash(String, JSON::Any)? = nil)
      end
    end
  end
end
