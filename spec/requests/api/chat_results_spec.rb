require "rails_helper"

RSpec.describe "Api::ChatResults", type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe "GET /api/chat_results/:job_id" do
    context "without authentication" do
      it "returns 401" do
        get api_chat_result_path("some-id")
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with unknown job_id" do
      it "returns 404" do
        get api_chat_result_path("nonexistent"),
          headers: auth_headers(user)

        expect(response).to have_http_status(:not_found)
      end
    end

    context "with pending result" do
      it "returns pending status" do
        cr = create(:chat_result, user: user, character: character, status: "pending")

        get api_chat_result_path(cr.job_id),
          headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["status"]).to eq("pending")
      end
    end

    context "with completed result" do
      it "returns response and usage" do
        cr = create(:chat_result, user: user, character: character,
          status: "completed", response: "Hello!", usage: { "tokens" => 10 })

        get api_chat_result_path(cr.job_id),
          headers: auth_headers(user)

        body = response.parsed_body
        expect(body["status"]).to eq("completed")
        expect(body["response"]).to eq("Hello!")
        expect(body["usage"]).to eq({ "tokens" => 10 })
      end
    end

    context "with failed result" do
      it "returns error message" do
        cr = create(:chat_result, user: user, character: character,
          status: "failed", error_message: "API error")

        get api_chat_result_path(cr.job_id),
          headers: auth_headers(user)

        body = response.parsed_body
        expect(body["status"]).to eq("failed")
        expect(body["error"]).to eq("API error")
      end
    end

    context "with another user's result" do
      it "returns 404" do
        other_user = create(:user)
        cr = create(:chat_result, user: other_user, character: create(:character, user: other_user))

        get api_chat_result_path(cr.job_id),
          headers: auth_headers(user)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
