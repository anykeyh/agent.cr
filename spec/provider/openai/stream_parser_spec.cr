require "../../spec_helper"

# A mock IO that honours `read_timeout=` (per-read semantics) and lets tests
# program per-line delays before the line is returned. Used by the timeout specs
# below to verify the parser applies the first-byte and idle budgets correctly.
# Returns lines in order; once exhausted, `#gets` returns nil (EOF). Every
# successful read resets the per-read timer because each `#gets` independently
# consults `read_timeout`.
private class MockTimeoutIO < IO
  property read_timeout : Time::Span?

  def initialize(@lines : Array(String), @delays : Array(Time::Span) = [] of Time::Span)
    @i = 0
    @read_timeout = nil
  end

  def read(slice : Bytes) : Int32
    raise "use gets"
  end

  def gets(chomp : Bool = true) : String?
    return nil if @i >= @lines.size
    delay = @i < @delays.size ? @delays[@i] : Time::Span.zero

    if t = @read_timeout
      # Honor the per-read timeout by racing the delay against it. The channel
      # signals when the programmed delay elapses; the select branch raises
      # IO::TimeoutError if the read_timeout fires first.
      ready = Channel(Nil).new
      spawn do
        sleep delay if delay > Time::Span.zero
        ready.send(nil)
      end
      select
      when ready.receive
        # delay elapsed — proceed to return the line
      when timeout(t)
        raise IO::TimeoutError.new("MockTimeoutIO: read timed out after #{t.total_milliseconds.round}ms")
      end
    elsif delay > Time::Span.zero
      sleep delay
    end

    line = @lines[@i]
    @i += 1
    chomp ? line : "#{line}\n"
  end

  def write(slice : Bytes) : Nil
    raise "not implemented"
  end
end

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
end

describe Agent::Provider::OpenAI::StreamParser do
  it "treats explicit reasoning:null as no chunk" do
    chunks, _reasoning = parse_lines([
      %(data: {"choices":[{"index":0,"delta":{"role":"assistant","reasoning":null},
        "finish_reason":"stop"}]}),
      "data: [DONE]",
    ])
    chunks.should be_empty
  end
end

# Wraps StreamParser.parse so the stream consumer fiber is set up before the
# parser pushes chunks (mirrors parse_lines above). Returns the parser's tuple
# on success, or raises whatever IO::TimeoutError was thrown.
private def parse_with_timeouts(
  io : IO,
  first_byte_timeout : Time::Span? = nil,
  idle_timeout : Time::Span? = nil,
  cancel : -> Bool = -> { false },
)
  response = Agent::Response.new
  spawn { response.stream { |_| } } # consume chunks so push_chunk doesn't block
  Fiber.yield
  msg, usage, finish = Agent::Provider::OpenAI::StreamParser.parse(
    io, response, cancel,
    first_byte_timeout: first_byte_timeout,
    idle_timeout: idle_timeout,
  )
  response.finish(msg, usage) unless response.finished?
  {response, msg, usage, finish}
end

# Per-read SSE timeout behaviour (AGENTS.md "dynamic read-timeout to fail-fast
# on hung SSE connections"). These exercise `StreamParser.parse`'s use of the
# `first_byte_timeout` / `idle_timeout` keyword args and confirm it:
#
#   1. doesn't time out under normal streaming
#   2. raises IO::TimeoutError when the first read exceeds `first_byte_timeout`
#   3. raises IO::TimeoutError when a mid-stream gap exceeds `idle_timeout`
#   4. treats comment / heartbeat lines as "any byte arrival" that resets the
#      idle timer
#   5. honours `first_byte_timeout_ms_per_token` from `Agent::Config`
#   6. falls back to `idle_timeout` for *all* reads (incl. the first) when
#      `compute_first_byte_timeout?` is false
#   7. lets caller cancellation short-circuit the parse loop and the response
#      surface as `cancelled?` (not `error?`)
describe Agent::Provider::OpenAI::StreamParser do
  it "does not time out under normal streaming" do
    # Each line arrives within 1ms; first-byte budget of 10ms and idle budget
    # of 10ms should both comfortably elapse without firing.
    io = MockTimeoutIO.new([
      %(data: {"choices":[{"index":0,"delta":{"content":"a"}}]}),
      %(data: {"choices":[{"index":0,"delta":{"content":"b"}}]}),
      %(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}),
      "data: [DONE]",
    ], delays: [1.milliseconds, 1.milliseconds, 1.milliseconds, 1.milliseconds])

    response, msg, _usage, _finish = parse_with_timeouts(io,
      first_byte_timeout: 10.milliseconds,
      idle_timeout: 10.milliseconds)
    msg.content.should eq("ab")
    response.error?.should be_false
  end

  it "raises IdleTimeoutError(:first_byte) on first-byte timeout" do
    # First read delayed past the 10ms first-byte budget. The parser wraps the
    # IO::TimeoutError raised by the underlying IO as an IdleTimeoutError with
    # phase :first_byte (no successful read has occurred yet).
    io = MockTimeoutIO.new([
      %(data: {"choices":[{"index":0,"delta":{"content":"a"}}]}),
    ], delays: [0.5.seconds])

    err = expect_raises(Agent::IdleTimeoutError) do
      parse_with_timeouts(io,
        first_byte_timeout: 10.milliseconds,
        idle_timeout: 10.milliseconds)
    end
    err.phase.should eq(:first_byte)
    err.cause.should be_a(IO::TimeoutError)
  end

  it "raises IdleTimeoutError(:idle) on inter-byte timeout" do
    # First line arrives fast; second line is delayed past the idle budget.
    # phase :idle because at least one line has been read successfully.
    io = MockTimeoutIO.new([
      %(data: {"choices":[{"index":0,"delta":{"content":"a"}}]}),
      %(data: {"choices":[{"index":0,"delta":{"content":"b"}}]}),
    ], delays: [1.milliseconds, 0.5.seconds])

    err = expect_raises(Agent::IdleTimeoutError) do
      parse_with_timeouts(io,
        first_byte_timeout: 10.milliseconds,
        idle_timeout: 10.milliseconds)
    end
    err.phase.should eq(:idle)
    err.cause.should be_a(IO::TimeoutError)
  end

  it "treats comment / heartbeat lines as idle-timer resets" do
    # Three lines each delayed by 25ms; idle budget is 30ms so each individual
    # gap fits within the budget. The `: OPENROUTER PROCESSING` comment line
    # arrives between two `data: {}` chunks — any byte arrival resets the idle
    # timer, so the gaps straddle two adjacent reads rather than accumulating.
    # Assert no raise (without the reset, the cumulative 75ms would exceed 30ms
    # — but per-read semantics mean only the gap between two consecutive
    # reads counts; each is 25ms so all is well).
    io = MockTimeoutIO.new([
      %(data: {"choices":[{"index":0,"delta":{"content":"a"}}]}),
      ": OPENROUTER PROCESSING",
      %(data: {"choices":[{"index":0,"delta":{"content":"b"}}]}),
    ], delays: [25.milliseconds, 25.milliseconds, 25.milliseconds])

    response, msg, _usage, _finish = parse_with_timeouts(io,
      first_byte_timeout: 1.second,
      idle_timeout: 30.milliseconds)
    msg.content.should eq("ab")
    response.error?.should be_false
  end

  it "honours Agent::Config first_byte_timeout_ms_per_token knob" do
    # With ms_per_token = 1000 (1s/token), a 1k-char prompt (~250 tokens)
    # yields ~250s added to the 3s base = 253s, below the 300s default max.
    config = Agent::Config.new(
      api_key: "test",
      api_endpoint: "http://localhost:1",
      first_byte_timeout_ms_per_token: 1000,
    )
    # 1000 chars / 4 = 250 tokens * 1000ms = 250000ms + 3000ms = 253s.
    config.compute_first_byte_timeout(1000).should eq(253.seconds)

    # At 100k chars, 25000 tokens * 1s + 3s = 25003s — clamp to 300s max.
    config.compute_first_byte_timeout(100_000).should eq(300.seconds)

    # Smaller base + tighter knobs: 1000 chars / 4 = 250 tokens * 10ms = 2500ms
    # = 2.5s; clamp to [1s, 5s] = 2.5s.
    tight = Agent::Config.new(
      api_key: "test",
      api_endpoint: "http://localhost:1",
      first_byte_timeout_ms_per_token: 10,
      first_byte_timeout_min: 1.seconds,
      first_byte_timeout_max: 5.seconds,
      first_byte_timeout_base: 0.seconds,
    )
    tight.compute_first_byte_timeout(1000).should eq(2.5.seconds)
  end

  it "uses idle_timeout for all reads when compute_first_byte_timeout? is false" do
    config = Agent::Config.new(
      api_key: "test",
      api_endpoint: "http://localhost:1",
      compute_first_byte_timeout: false,
      idle_byte_timeout: 30.milliseconds,
    )
    config.compute_first_byte_timeout(1_000_000).should be_nil
    config.idle_byte_timeout.should eq(30.milliseconds)

    # When the parser is called with first_byte_timeout: nil, both the first
    # and subsequent reads should fall back to idle_timeout. The first read is
    # fast (1ms — well within 30ms) but would time out if first-byte budget
    # were 0ms (which compute_first_byte_timeout would return at 0 prompt bytes).
    # Inverse test: a first-read delay of 0.5s with idle_timeout=10ms must
    # raise — i.e. idle_timeout applies to the first read too.
    io = MockTimeoutIO.new([
      %(data: {"choices":[{"index":0,"delta":{"content":"a"}}]}),
    ], delays: [0.5.seconds])

    err = expect_raises(Agent::IdleTimeoutError) do
      parse_with_timeouts(io, first_byte_timeout: nil, idle_timeout: 10.milliseconds)
    end
    err.phase.should eq(:first_byte)
    err.timeout.should eq(10.milliseconds)
  end

  it "lets caller cancellation short-circuit the parse loop" do
    # The mock IO's first read is delayed long enough that the parser is parked
    # when the caller flips the cancel flag; on the next loop iteration
    # `break if cancel.call` exits cleanly. We use a 0-delay then a long-delay:
    # the parser blocks on the second read; the cancel proc returns true, the
    # parser breaks before raising IO::TimeoutError.
    io = MockTimeoutIO.new([
      %(data: {"choices":[{"index":0,"delta":{"content":"a"}}]}),
      %(data: {"choices":[{"index":0,"delta":{"content":"b"}}]}),
    ], delays: [1.milliseconds, 1.second])

    response = Agent::Response.new
    cancelled = false
    spawn { response.stream { |_| } }
    Fiber.yield

    spawn do
      sleep 50.milliseconds
      cancelled = true
      response.cancel
    end

    cancel_proc = -> { cancelled }
    msg, _usage, _finish = Agent::Provider::OpenAI::StreamParser.parse(
      io, response, cancel_proc,
      first_byte_timeout: 10.seconds,
      idle_timeout: 10.seconds,
    )
    response.finish(msg, Agent::Usage.new) unless response.finished?

    response.cancelled?.should be_true
    response.error?.should be_false
  end
end
