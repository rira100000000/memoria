require "rails_helper"

RSpec.describe ReflectionService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, system_prompt: "You are a helpful assistant.") }

  let(:gemini_response_data) do
    {
      "candidates" => [{
        "content" => {
          "parts" => [{ "text" => <<~JSON }],
            ```json
            {
              "conversationTitle": "テスト会話",
              "tags": ["テスト", "挨拶"],
              "mood": "明るい",
              "keyTakeaways": ["テストは成功した"],
              "actionItems": [],
              "reflectionBody": "## テーマ\\nテストの会話",
              "semanticDefinitions": []
            }
            ```
          JSON
          "role" => "model",
        },
      }],
      "usageMetadata" => { "promptTokenCount" => 100, "candidatesTokenCount" => 50, "totalTokenCount" => 150 },
    }
  end

  let(:embed_response_data) do
    { "embedding" => { "values" => Array.new(768) { rand } } }
  end

  let(:mock_gemini_client) { instance_double(Gemini::Client) }

  before do
    allow(Gemini::Client).to receive(:new).and_return(mock_gemini_client)
    allow(mock_gemini_client).to receive(:chat).and_return(Gemini::Response.new(gemini_response_data))
    allow(mock_gemini_client).to receive(:embeddings).and_return(Gemini::Response.new(embed_response_data))

    # Ensure vault directory exists
    vault_path = character.vault_path
    FileUtils.mkdir_p(File.join(vault_path, "TagProfilingNote"))
    FileUtils.mkdir_p(File.join(vault_path, "SummaryNote"))
    FileUtils.mkdir_p(File.join(vault_path, "FullLog"))
  end

  after do
    FileUtils.rm_rf(character.vault_path) if Dir.exist?(character.vault_path)
  end

  describe "#generate" do
    it "returns nil for empty conversation" do
      service = described_class.new(character)
      result = service.generate(conversation_text: "")
      expect(result).to be_nil
    end

    it "generates a summary note from conversation text" do
      service = described_class.new(character)
      result = service.generate(
        conversation_text: "User: こんにちは\n#{character.name}: やっほー",
        full_log_ref: "20260404120000.md"
      )

      expect(result).not_to be_nil
      expect(result[:base_name]).to include("SN-")
      expect(result[:tags]).to include(character.name)
      expect(result[:file_path]).to include("SummaryNote/")
    end

    it "accepts custom timestamp" do
      service = described_class.new(character)
      result = service.generate(
        conversation_text: "User: test",
        timestamp: "202601011200"
      )

      expect(result[:base_name]).to start_with("SN-202601011200")
    end
  end
end
