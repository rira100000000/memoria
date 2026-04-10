require "rails_helper"

RSpec.describe "Api::Summarize", type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe "POST /api/characters/:id/summarize" do
    context "without authentication" do
      it "returns 401" do
        post summarize_api_character_path(character)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "without conversation_text" do
      it "returns 400" do
        post summarize_api_character_path(character),
          headers: auth_headers(user),
          params: { conversation_text: "" },
          as: :json

        expect(response).to have_http_status(:bad_request)
      end
    end

    context "with valid params" do
      it "returns 202 with job_id" do
        post summarize_api_character_path(character),
          headers: auth_headers(user),
          params: {
            conversation_text: "User: こんにちは\nHAL: やっほー",
            full_log_ref: "20260404120000.md",
          },
          as: :json

        expect(response).to have_http_status(:accepted)
        body = response.parsed_body
        expect(body["job_id"]).to be_present
        expect(body["poll_url"]).to include("chat_results")
      end

      it "enqueues SummarizeJob" do
        expect {
          post summarize_api_character_path(character),
            headers: auth_headers(user),
            params: { conversation_text: "User: test" },
            as: :json
        }.to have_enqueued_job(SummarizeJob)
      end

      it "stores metadata in ChatResult.usage" do
        post summarize_api_character_path(character),
          headers: auth_headers(user),
          params: {
            conversation_text: "User: test",
            full_log_ref: "log.md",
            full_log_path: "FullLog/log.md",
            timestamp: "202601011200",
          },
          as: :json

        cr = ChatResult.last
        expect(cr.usage["full_log_ref"]).to eq("log.md")
        expect(cr.usage["full_log_path"]).to eq("FullLog/log.md")
        expect(cr.usage["timestamp"]).to eq("202601011200")
      end
    end
  end
end
