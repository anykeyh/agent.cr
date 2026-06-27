require "./spec_helper"

describe Agent do
  describe "#embed" do
    it "returns a float vector from the API" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
          embed_model: "text-embedding-3-small",
        )

        agent = Agent.new(config)
        vector = agent.embed("Hello world")

        vector.should be_a(Array(Float64))
        vector.size.should eq(1536)
        # Deterministic: based on input length
        vector[0].should eq((("Hello world".size + 0) % 100) / 100.0)
      end
    end

    it "uses embed_model from config when no model is passed" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
          embed_model: "text-embedding-3-large",
        )

        agent = Agent.new(config)
        vector = agent.embed("test")

        # text-embedding-3-large returns 3072 dimensions
        vector.size.should eq(3072)
      end
    end

    it "allows overriding model per-call" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
          embed_model: "text-embedding-3-small",
        )

        agent = Agent.new(config)
        vector = agent.embed("test", model: "text-embedding-3-large")

        vector.size.should eq(3072)
      end
    end

    it "raises ArgumentError when no model is resolved" do
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:1",
      )

      agent = Agent.new(config)
      expect_raises(ArgumentError, /No model specified/) do
        agent.embed("Hello")
      end
    end

    it "raises ApiError on non-2xx status" do
      server = HTTP::Server.new do |ctx|
        if ctx.request.method == "POST" && ctx.request.path.includes?("/embeddings")
          ctx.response.status_code = 401
          ctx.response.puts "Unauthorized"
          ctx.response.close
        else
          ctx.response.status_code = 404
        end
      end

      address = server.bind_tcp(0)
      port = address.port
      ready = Channel(Nil).new
      spawn do
        ready.send(nil)
        server.listen
      end
      ready.receive

      begin
        config = Agent::Config.new(
          api_key: "bad-key",
          api_endpoint: "http://localhost:#{port}",
          embed_model: "text-embedding-3-small",
        )

        agent = Agent.new(config)
        expect_raises(Agent::ApiError) do
          agent.embed("Hello")
        end
      ensure
        server.close
      end
    end

    it "raises ConnectionError on network failure" do
      config = Agent::Config.new(
        api_key: "test-key",
        api_endpoint: "http://localhost:1",
        embed_model: "text-embedding-3-small",
      )

      agent = Agent.new(config)
      expect_raises(Agent::ConnectionError) do
        agent.embed("Hello")
      end
    end

    it "raises ClosedError when agent is closed" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
          embed_model: "text-embedding-3-small",
        )

        agent = Agent.new(config)
        agent.close
        expect_raises(Agent::ClosedError) do
          agent.embed("Hello")
        end
      end
    end

    it "runs through handler chain" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
          embed_model: "text-embedding-3-small",
        )

        agent = Agent.new(config)

        log = [] of String
        agent.use(Agent::Spec::RecordingEmbedHandler.new(log))

        agent.embed("test")
        log.should eq(["before", "after"])
      end
    end

    it "handler can mutate the input and model" do
      with_mock_server do |port|
        config = Agent::Config.new(
          api_key: "test-key",
          api_endpoint: "http://localhost:#{port}",
          embed_model: "text-embedding-3-small",
        )

        agent = Agent.new(config)

        agent.use(Agent::Spec::OverrideEmbedHandler.new)

        # The handler overrides input to "overridden" and model to "text-embedding-3-large"
        vector = agent.embed("ignored")
        vector.size.should eq(3072) # text-embedding-3-large → 3072
      end
    end
  end
end
