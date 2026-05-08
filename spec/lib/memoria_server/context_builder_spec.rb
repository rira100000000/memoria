require "rails_helper"

RSpec.describe MemoriaServer::ContextBuilder do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, name: "TestChar") }
  let(:device) { create(:device, slug: "test-pc") }

  describe ".build" do
    it "extracts current_input from last user message" do
      payload = {
        "messages" => [
          { "role" => "user", "content" => "first" },
          { "role" => "assistant", "content" => "reply" },
          { "role" => "user", "content" => "second" }
        ]
      }
      ctx = described_class.build(character: character, device: device, payload: payload)
      expect(ctx[:current_input]).to eq("second")
    end

    it "extracts client_system_prompt from system messages" do
      payload = {
        "messages" => [
          { "role" => "system", "content" => "you are a cat" },
          { "role" => "user", "content" => "hi" }
        ]
      }
      ctx = described_class.build(character: character, device: device, payload: payload)
      expect(ctx[:client_system_prompt]).to eq("you are a cat")
    end

    it "concatenates multiple system messages" do
      payload = {
        "messages" => [
          { "role" => "system", "content" => "rule 1" },
          { "role" => "system", "content" => "rule 2" },
          { "role" => "user", "content" => "hi" }
        ]
      }
      ctx = described_class.build(character: character, device: device, payload: payload)
      expect(ctx[:client_system_prompt]).to eq("rule 1\n\nrule 2")
    end

    it "extracts text from vision content arrays" do
      payload = {
        "messages" => [
          { "role" => "user", "content" => [
            { "type" => "text", "text" => "what is this?" },
            { "type" => "image_url", "image_url" => { "url" => "data:..." } }
          ] }
        ]
      }
      ctx = described_class.build(character: character, device: device, payload: payload)
      expect(ctx[:current_input]).to eq("what is this?")
    end

    it "passes through tools and tool_choice" do
      payload = {
        "messages" => [ { "role" => "user", "content" => "x" } ],
        "tools" => [ { "type" => "function", "function" => { "name" => "f" } } ],
        "tool_choice" => "auto"
      }
      ctx = described_class.build(character: character, device: device, payload: payload)
      expect(ctx[:tools]).to be_present
      expect(ctx[:tool_choice]).to eq("auto")
    end

    it "computes elapsed_since from last_interaction_at" do
      payload = { "messages" => [ { "role" => "user", "content" => "hi" } ] }
      one_hour_ago = 1.hour.ago
      ctx = described_class.build(character: character, device: device, payload: payload, last_interaction_at: one_hour_ago)
      expect(ctx[:elapsed_since]).to be_within(5).of(3600)
    end

    it "handles nil device" do
      payload = { "messages" => [ { "role" => "user", "content" => "hi" } ] }
      ctx = described_class.build(character: character, device: nil, payload: payload)
      expect(ctx[:device_id]).to be_nil
      expect(ctx[:device_slug]).to be_nil
    end

    it "passes through x_memoria capability declarations" do
      payload = {
        "messages" => [{ "role" => "user", "content" => "hi" }],
        "x_memoria" => { "wants" => ["emotion"] },
      }
      ctx = described_class.build(character: character, device: device, payload: payload)
      expect(ctx[:x_memoria]).to eq({ wants: ["emotion"] })
    end

    it "defaults x_memoria to empty hash when absent" do
      payload = { "messages" => [{ "role" => "user", "content" => "hi" }] }
      ctx = described_class.build(character: character, device: device, payload: payload)
      expect(ctx[:x_memoria]).to eq({})
    end
  end
end
