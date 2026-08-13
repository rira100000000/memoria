require "rails_helper"

RSpec.describe "Api::Chats", type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe "POST /api/characters/:id/chat" do
    context "without authentication" do
      it "returns 401" do
        post chat_api_character_path(character)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "without message" do
      it "returns 400" do
        post chat_api_character_path(character),
          headers: auth_headers(user),
          params: { message: "" },
          as: :json

        expect(response).to have_http_status(:bad_request)
      end
    end

    context "async mode (default)" do
      it "returns 202 with job_id and poll_url" do
        post chat_api_character_path(character),
          headers: auth_headers(user),
          params: { message: "hello" },
          as: :json

        expect(response).to have_http_status(:accepted)
        body = response.parsed_body
        expect(body["job_id"]).to be_present
        expect(body["status"]).to eq("pending")
        expect(body["poll_url"]).to include("chat_results")
      end

      it "creates a ChatResult record" do
        expect {
          post chat_api_character_path(character),
            headers: auth_headers(user),
            params: { message: "hello" },
            as: :json
        }.to change(ChatResult, :count).by(1)
      end

      it "enqueues a ChatJob" do
        expect {
          post chat_api_character_path(character),
            headers: auth_headers(user),
            params: { message: "hello" },
            as: :json
        }.to have_enqueued_job(ChatJob)
      end
    end

    context "sync mode" do
      let(:mock_result) { { response: "Hi!", usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } } }

      before do
        mock_session = instance_double(ChatSession, send_message: mock_result)
        allow(ChatSession).to receive(:find_or_create).and_return(mock_session)
      end

      it "returns response inline" do
        post chat_api_character_path(character),
          headers: auth_headers(user),
          params: { message: "hello", sync: "true" },
          as: :json

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["response"]).to eq("Hi!")
        expect(body["usage"]["input_tokens"]).to eq(10)
      end
    end
  end

  describe "POST /api/characters/:id/reset" do
    it "returns success for no active session" do
      post reset_api_character_path(character),
        headers: auth_headers(user),
        as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["message"]).to include("No active session")
    end
  end
end
