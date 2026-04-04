require "rails_helper"

RSpec.describe LlmClient do
  let(:gemini_response_data) do
    {
      "candidates" => [{
        "content" => {
          "parts" => [{ "text" => "Hello there!" }],
          "role" => "model",
        },
      }],
      "usageMetadata" => {
        "promptTokenCount" => 10,
        "candidatesTokenCount" => 5,
        "totalTokenCount" => 15,
      },
    }
  end

  let(:mock_gemini_client) { instance_double(Gemini::Client) }
  let(:mock_response) { Gemini::Response.new(gemini_response_data) }

  before do
    allow(Gemini::Client).to receive(:new).and_return(mock_gemini_client)
  end

  describe "#generate" do
    it "returns text and usage from Gemini response" do
      allow(mock_gemini_client).to receive(:chat).and_return(mock_response)

      client = LlmClient.new(api_key: "test-key")
      result = client.generate("Hello")

      expect(result[:text]).to eq("Hello there!")
      expect(result[:usage][:input_tokens]).to eq(10)
      expect(result[:usage][:output_tokens]).to eq(5)
      expect(result[:usage][:total_tokens]).to eq(15)
    end

    it "uses light model when tier is :light" do
      allow(mock_gemini_client).to receive(:chat).and_return(mock_response)

      client = LlmClient.new(api_key: "test-key", main_model: "main", light_model: "light")
      client.generate("Hello", tier: :light)

      expect(mock_gemini_client).to have_received(:chat) do |args|
        expect(args[:parameters][:model]).to eq("light")
      end
    end

    it "calls usage_tracker with model and usage" do
      allow(mock_gemini_client).to receive(:chat).and_return(mock_response)
      tracked = nil
      tracker = ->(model, usage) { tracked = { model: model, usage: usage } }

      client = LlmClient.new(api_key: "test-key", usage_tracker: tracker)
      client.generate("Hello")

      expect(tracked[:model]).to include("gemini")
      expect(tracked[:usage][:input_tokens]).to eq(10)
    end
  end

  describe "#chat" do
    it "passes messages and system_instruction to Gemini" do
      allow(mock_gemini_client).to receive(:chat).and_return(mock_response)

      client = LlmClient.new(api_key: "test-key")
      messages = [{ role: "user", parts: [{ text: "Hi" }] }]
      client.chat(messages, system_instruction: "Be helpful")

      expect(mock_gemini_client).to have_received(:chat) do |args|
        expect(args[:parameters][:contents]).to eq(messages)
        expect(args[:parameters][:systemInstruction]).to be_present
      end
    end
  end

  describe "#chat with function calls" do
    let(:fc_response_data) do
      {
        "candidates" => [{
          "content" => {
            "parts" => [
              { "functionCall" => { "name" => "search", "args" => { "query" => "test" } } },
            ],
            "role" => "model",
          },
        }],
        "usageMetadata" => { "promptTokenCount" => 5, "candidatesTokenCount" => 3, "totalTokenCount" => 8 },
      }
    end

    it "extracts function calls from response" do
      allow(mock_gemini_client).to receive(:chat).and_return(Gemini::Response.new(fc_response_data))

      client = LlmClient.new(api_key: "test-key")
      result = client.chat([{ role: "user", parts: [{ text: "search" }] }])

      expect(result[:function_calls]).to eq([{ name: "search", args: { "query" => "test" } }])
    end
  end

  describe "#embed" do
    it "returns embedding values" do
      embed_data = { "embedding" => { "values" => [0.1, 0.2, 0.3] } }
      embed_response = Gemini::Response.new(embed_data)
      allow(mock_gemini_client).to receive(:embeddings).and_return(embed_response)

      client = LlmClient.new(api_key: "test-key")
      result = client.embed("test text")

      expect(result).to eq([0.1, 0.2, 0.3])
    end
  end

  describe "#send_function_response" do
    it "appends function responses and calls chat" do
      allow(mock_gemini_client).to receive(:chat).and_return(mock_response)

      client = LlmClient.new(api_key: "test-key")
      messages = [{ role: "user", parts: [{ text: "search" }] }]
      function_responses = [{ name: "search", response: { results: "found" } }]

      client.send_function_response(messages, function_responses)

      expect(mock_gemini_client).to have_received(:chat) do |args|
        contents = args[:parameters][:contents]
        expect(contents.length).to eq(2)
        expect(contents.last[:parts].first).to have_key(:functionResponse)
      end
    end
  end
end
