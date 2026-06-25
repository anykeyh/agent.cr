require "./spec_helper"

describe Agent::Config do
  it "defaults endpoint and model" do
    config = Agent::Config.new(api_key: "sk-test")
    config.api_endpoint.should eq("https://api.openai.com/v1")
    config.model.should eq("gpt-4o")
  end

  it "accepts custom values" do
    config = Agent::Config.new(
      api_key: "sk-custom",
      api_endpoint: "https://myapi.local/v1",
      model: "gpt-4o-mini",
      system_prompt: "Be helpful",
      max_tokens: 512,
      temperature: 0.7
    )
    config.api_key.should eq("sk-custom")
    config.api_endpoint.should eq("https://myapi.local/v1")
    config.model.should eq("gpt-4o-mini")
    config.system_prompt.should eq("Be helpful")
    config.max_tokens.should eq(512)
    config.temperature.should eq(0.7)
  end
end
