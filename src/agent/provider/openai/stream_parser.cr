class Agent
  module Provider
    class OpenAI
      # Accumulates a tool call across multiple SSE deltas.
      # Must be a class (reference type) so the hash entry is mutated in place.
      private class ToolCallDelta
        property id : String
        property name : String
        property arguments : String

        def initialize
          @id = ""
          @name = ""
          @arguments = ""
        end
      end

      # Parses an OpenAI SSE streaming response.
      module StreamParser
        extend self

        def parse(
          body_io : IO,
          response : Response,
          cancel : -> Bool,
        ) : {Message, Usage, String?}
          tool_call_deltas = {} of Int32 => ToolCallDelta
          content_buffer = String::Builder.new
          reasoning_buffer = String::Builder.new
          usage = Usage.new
          finish_reason = nil

          body_io.each_line do |line|
            # Check for cancellation
            if cancel.call
              break
            end

            line = line.strip
            next if line.empty?
            next unless line.starts_with?("data:")

            # SSE sentinel — skip [DONE] (with or without space after data:)
            rest = line[5..].lstrip(' ')
            next if rest.starts_with?("[DONE]")

            json = begin
              JSON.parse(rest)
            rescue JSON::ParseException
              next
            end
            parsed = json.as_h? || next

            usage = parse_usage(parsed, usage)
            finish_reason = process_deltas(parsed, response, content_buffer, reasoning_buffer, tool_call_deltas) || finish_reason
          end

          final_message = build_final_message(content_buffer, reasoning_buffer, tool_call_deltas)
          {final_message, usage, finish_reason}
        end

        private def parse_usage(parsed : Hash(String, JSON::Any), prev_usage : Usage) : Usage
          if usage_data = parsed["usage"]?
            if u = usage_data.as_h?
              return Usage.new(
                prompt_tokens: u["prompt_tokens"]?.try(&.as_i),
                completion_tokens: u["completion_tokens"]?.try(&.as_i),
                total_tokens: u["total_tokens"]?.try(&.as_i)
              )
            end
          elsif timings = parsed["timings"]?
            if timings_h = timings.as_h?
              prompt_n = timings_h["prompt_n"]?.try(&.as_i)
              predicted_n = timings_h["predicted_n"]?.try(&.as_i)
              return Usage.new(
                prompt_tokens: prev_usage.prompt_tokens || prompt_n,
                completion_tokens: prev_usage.completion_tokens || predicted_n,
                total_tokens: prev_usage.total_tokens || (prompt_n && predicted_n ? prompt_n + predicted_n : nil)
              )
            end
          end
          prev_usage
        end

        private def process_deltas(
          parsed : Hash(String, JSON::Any),
          response : Response,
          content_buffer : String::Builder,
          reasoning_buffer : String::Builder,
          tool_call_deltas : Hash(Int32, ToolCallDelta),
        ) : String?
          finish_reason = nil

          choices = parsed["choices"]?.try(&.as_a?) || [] of JSON::Any
          choices.each do |choice|
            delta = choice["delta"]?.try(&.as_h?) || next

            if reason = choice["finish_reason"]?.try(&.as_s?)
              finish_reason = reason
            end

            if c = delta["content"]?.try(&.as_s?)
              content_buffer << c
              response.push_chunk(Response::Chunk.new(c, Response::ChunkKind::Content))
            end

            if rc = delta["reasoning_content"]?.try(&.as_s?)
              reasoning_buffer << rc
              response.push_chunk(Response::Chunk.new(rc, Response::ChunkKind::Reasoning))
            end

            process_tool_call_deltas(delta, tool_call_deltas, response)
          end

          finish_reason
        end

        private def process_tool_call_deltas(
          delta : Hash(String, JSON::Any),
          tool_call_deltas : Hash(Int32, ToolCallDelta),
          response : Response,
        ) : Nil
          tc_delta = delta["tool_calls"]?.try(&.as_a?) || return
          tc_delta.each_with_index do |tcd_any, pos|
            tcd = tcd_any.as_h? || next
            # Use the API-provided index if present, otherwise fall back to
            # positional order (handles providers that omit the index field).
            idx = tcd["index"]?.try(&.as_i) || pos

            entry = tool_call_deltas[idx] ||= ToolCallDelta.new
            update_tool_call_id(entry, tcd)
            update_tool_call_function(entry, tcd, response)
          end
        end

        private def update_tool_call_id(entry : ToolCallDelta, tcd : Hash(String, JSON::Any)) : Nil
          if id = tcd["id"]?
            if id_s = id.as_s?
              entry.id = id_s
            end
          end
        end

        private def update_tool_call_function(entry : ToolCallDelta, tcd : Hash(String, JSON::Any), response : Response) : Nil
          fn = tcd["function"]? || return
          fn_h = fn.as_h? || return

          if fn_h_name = fn_h["name"]?
            if name_str = fn_h_name.as_s?
              if entry.name.empty?
                response.push_chunk(Response::Chunk.new(name_str, Response::ChunkKind::ToolCallName))
              end
              entry.name = name_str
            end
          end

          if fn_h_args = fn_h["arguments"]?
            if args_str = fn_h_args.as_s?
              entry.arguments += args_str
              response.push_chunk(Response::Chunk.new(args_str, Response::ChunkKind::ToolCallArgs))
            end
          end
        end

        private def build_final_message(
          content_buffer : String::Builder,
          reasoning_buffer : String::Builder,
          tool_call_deltas : Hash(Int32, ToolCallDelta),
        ) : Message
          full_content = content_buffer.to_s
          reasoning_content = reasoning_buffer.to_s

          tool_calls = if tool_call_deltas.empty?
                         nil
                       else
                         tool_call_deltas.map do |_idx, delta|
                           ToolCall.new(id: delta.id, name: delta.name, arguments: delta.arguments)
                         end
                       end

          content = full_content
          content = nil if tool_calls && full_content.empty?

          Message.new(
            role: Role::Assistant,
            content: content,
            tool_calls: tool_calls,
            reasoning: reasoning_content.empty? ? nil : reasoning_content,
          )
        end
      end
    end
  end
end
