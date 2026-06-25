require "./spec_helper"

describe Agent::Message do
  it "builds a simple text message body" do
    msg = Agent::Message.new(role: Agent::Role::User, content: "Hello")
    body = msg.to_request_body
    body["role"].as_s.should eq("user")
    body["content"].as_s.should eq("Hello")
  end

  it "builds a multimodal message body" do
    parts = [
      Agent::ContentPart.new(text: "What is this?"),
      Agent::ContentPart.new(image_url: "https://example.com/img.jpg"),
    ]
    msg = Agent::Message.new(role: Agent::Role::User, content_parts: parts)
    body = msg.to_request_body
    content = body["content"].as_a
    content[0].as_h["type"].as_s.should eq("text")
    content[1].as_h["type"].as_s.should eq("image_url")
  end

  it "builds a message with tool calls" do
    tool_calls = [Agent::ToolCall.new(id: "call_1", name: "get_weather", arguments: %({"city":"Paris"}))]
    msg = Agent::Message.new(role: Agent::Role::Assistant, tool_calls: tool_calls)
    body = msg.to_request_body
    body["tool_calls"].as_a.size.should eq(1)
  end

  it "detects tool calls via has_tool_calls?" do
    msg = Agent::Message.new(role: Agent::Role::Assistant, content: "Hello")
    msg.has_tool_calls?.should be_false

    tcs = [Agent::ToolCall.new(id: "c1", name: "fn", arguments: "{}")]
    msg2 = Agent::Message.new(role: Agent::Role::Assistant, tool_calls: tcs)
    msg2.has_tool_calls?.should be_true
  end
end

describe Agent::ContentPart do
  it "produces image JSON" do
    part = Agent::ContentPart.new(image_url: "https://ex.com/i.png", image_detail: "high")
    json = part.to_json_body
    json["type"].as_s.should eq("image_url")
  end

  it "produces text JSON" do
    part = Agent::ContentPart.new(text: "Hello")
    json = part.to_json_body
    json["type"].as_s.should eq("text")
    json["text"].as_s.should eq("Hello")
  end
end

describe Agent::ToolCall do
  it "stores tool call data" do
    tc = Agent::ToolCall.new(id: "tc_1", name: "fn", arguments: "{}")
    tc.id.should eq("tc_1")
    tc.name.should eq("fn")
    tc.arguments.should eq("{}")
  end
end

describe Agent::Usage do
  it "defaults to nil fields" do
    u = Agent::Usage.new
    u.prompt_tokens.should be_nil
    u.completion_tokens.should be_nil
    u.total_tokens.should be_nil
  end

  it "accepts values" do
    u = Agent::Usage.new(prompt_tokens: 10, completion_tokens: 20, total_tokens: 30)
    u.total_tokens.should eq(30)
  end
end
