require "./spec_helper"

private def api_error(status = 429, **headers)
  h = HTTP::Headers.new
  headers.each { |k, v| h[k.to_s.tr("_", "-")] = v }
  Agent::ApiError.new(status, "x", headers: h)
end

describe Agent::ApiError do
  it "reads Retry-After in seconds, as an HTTP date, and retry-after-ms" do
    api_error(retry_after: "2").retry_after.should eq(2.seconds)
    api_error(retry_after_ms: "250").retry_after.should eq(250.milliseconds)
    at = Time.utc + 30.seconds
    wait = api_error(retry_after: HTTP.format_time(at)).retry_after.as(Time::Span)
    wait.should be_close(30.seconds, 2.seconds)
    api_error(retry_after: HTTP.format_time(Time.utc - 1.minute)).retry_after.should eq(Time::Span.zero)
    api_error(retry_after: "soon").retry_after.should be_nil
  end

  it "survives absurd Retry-After values" do
    api_error(retry_after: "2592000").retry_after.should eq(30.days)
    api_error(retry_after: "1e300").retry_after.should be_nil
    api_error(retry_after: "Infinity").retry_after.should be_nil
    api_error(retry_after: "NaN").retry_after.should be_nil
    api_error(retry_after: "-5").retry_after.should be_nil
    api_error(retry_after: "9" * 400).retry_after.should eq(Agent::ApiError::MAX_RETRY_AFTER)
    api_error(retry_after: "Fri, 01 Jan 9999 00:00:00 GMT").retry_after.should eq(Agent::ApiError::MAX_RETRY_AFTER)
    api_error(retry_after_ms: "1e300").retry_after.should be_nil
  end

  it "decides retryability from the status unless x-should-retry says otherwise" do
    {408, 409, 429, 500, 503}.each { |code| api_error(code).retryable?.should be_true }
    {400, 401, 402, 404, 422}.each { |code| api_error(code).retryable?.should be_false }
    api_error(500, x_should_retry: "false").retryable?.should be_false
    api_error(400, x_should_retry: "true").retryable?.should be_true
  end
end

describe Agent::StreamError do
  it "takes retryability from a status-like or transient code" do
    Agent::StreamError.new("x", "502").retryable?.should be_true
    Agent::StreamError.new("x", "402").retryable?.should be_false
    Agent::StreamError.new("x", "overloaded_error").retryable?.should be_true
    Agent::StreamError.new("x", "invalid_request_error").retryable?.should be_false
    Agent::StreamError.new("x").retryable?.should be_false
    Agent::StreamError.new("x", retryable: true).retryable?.should be_true
  end
end
