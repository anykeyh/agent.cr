require "../../spec_helper"

# Helper: feed `lines` through the parser; collect reasoning chunks and the
# final Message#reasoning.
#
# Mirrors the real caller: `#stream` must be active while the parser pushes
# chunks (otherwise `push_chunk` drops them), and `#finish` closes the chunk
# channel so the stream consumer returns.
private def parse_lines(lines : Array(String))
  response = Agent::Response.new
  reasoning_chunks = [] of String
  collected = Channel(String).new

  spawn do
    response.stream { |c| collected.send(c.text) if c.reasoning? }
    collected.close
  end
  # Let the stream fiber run so `@streaming` is set before the parser pushes
  # chunks (otherwise `push_chunk` drops them).
  Fiber.yield

  io = IO::Memory.new(lines.join('\n'))
  msg, usage, _finish = Agent::Provider::OpenAI::StreamParser.parse(io, response, -> { false })
  response.finish(msg, usage)

  collected.each { |text| reasoning_chunks << text }
  {reasoning_chunks, msg.reasoning}
end

describe Agent::Provider::OpenAI::StreamParser do
  it "reads delta.reasoning_content (DeepSeek native)" do
    chunks, reasoning = parse_lines([
      %(data: {"choices":[{"index":0,"delta":{"reasoning_content":"Hello "}}]}),
      %(data: {"choices":[{"index":0,"delta":{"reasoning_content":"world"}}]}),
      %(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}),
      "data: [DONE]",
    ])
    chunks.should eq(["Hello ", "world"])
    reasoning.should eq("Hello world")
  end

  it "reads delta.reasoning (OpenRouter)" do
    chunks, reasoning = parse_lines([
      %(data: {"choices":[{"index":0,"delta":{"content":"","role":"assistant","reasoning":"We","reasoning_details":[{"type":"reasoning.text","text":"We","format":"unknown","index":0}]},"finish_reason":null}]}),
      %(data: {"choices":[{"index":0,"delta":{"content":"","role":"assistant","reasoning":" need","reasoning_details":[{"type":"reasoning.text","text":" need","format":"unknown","index":0}]},"finish_reason":null}]}),
      %(data: {"choices":[{"index":0,"delta":{"content":"hello","role":"assistant"},"finish_reason":"stop"}]}),
      "data: [DONE]",
    ])
    chunks.should eq(["We", " need"])
    reasoning.should eq("We need")
  end

  it "reads delta.reasoning_details without a string field" do
    chunks, reasoning = parse_lines([
      %(data: {"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.text","text":"Step "},{"type":"reasoning.text","text":"one"}]}}]}),
      "data: [DONE]",
    ])
    chunks.should eq(["Step one"])
    reasoning.should eq("Step one")
  end

  it "does not double-count when both reasoning and reasoning_details are present" do
    chunks, reasoning = parse_lines([
      %(data: {"choices":[{"index":0,"delta":{"reasoning":"We","reasoning_details":[{"type":"reasoning.text","text":"We","format":"unknown","index":0}]}}]}),
      "data: [DONE]",
    ])
    chunks.should eq(["We"])
    reasoning.should eq("We")
  end

  it "treats explicit reasoning:null as no chunk" do
    chunks, _reasoning = parse_lines([
      %(data: {"choices":[{"index":0,"delta":{"role":"assistant","reasoning":null},
        "finish_reason":"stop"}]}),
      "data: [DONE]",
    ])
    chunks.should be_empty
  end
end
