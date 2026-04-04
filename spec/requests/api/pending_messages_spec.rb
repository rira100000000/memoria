require "rails_helper"

RSpec.describe "Api::PendingMessages", type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe "GET /api/pending_messages" do
    it "returns unread messages" do
      msg = create(:pending_message, character: character, user: user, status: "pending")
      create(:pending_message, character: character, user: user, status: "read")

      get api_pending_messages_path, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.length).to eq(1)
      expect(body.first["id"]).to eq(msg.id)
      expect(body.first["content"]).to eq(msg.content)
      expect(body.first["character_name"]).to eq(character.name)
    end

    it "filters by character_id" do
      other_char = create(:character, user: user)
      create(:pending_message, character: character, user: user)
      create(:pending_message, character: other_char, user: user)

      get api_pending_messages_path, headers: auth_headers(user),
        params: { character_id: character.id }

      expect(response.parsed_body.length).to eq(1)
    end

    it "does not return other users messages" do
      other_user = create(:user)
      other_char = create(:character, user: other_user)
      create(:pending_message, character: other_char, user: other_user)

      get api_pending_messages_path, headers: auth_headers(user)

      expect(response.parsed_body).to be_empty
    end
  end

  describe "PATCH /api/pending_messages/:id/read" do
    it "marks message as read" do
      msg = create(:pending_message, character: character, user: user)

      patch read_api_pending_message_path(msg), headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(msg.reload.status).to eq("read")
    end

    it "returns 404 for other user's message" do
      other_user = create(:user)
      other_char = create(:character, user: other_user)
      msg = create(:pending_message, character: other_char, user: other_user)

      patch read_api_pending_message_path(msg), headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
    end
  end
end
