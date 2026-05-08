Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    # MemoriaServer v1 — OpenAI互換 + プレゼンス管理
    namespace :v1 do
      get "ping", to: "ping#show"
      get "ping/admin", to: "ping#admin"

      # OpenAI Chat Completions 互換
      post "chat/completions", to: "chat_completions#create"

      # Device 管理
      resources :devices, only: [:index, :show], param: :slug do
        post :heartbeat, on: :member
        get  :events,    on: :member  # SSE 常駐イベントチャンネル
      end

      # Character スコープ（プレゼンス・push 系）
      # ref は id（数値）または vault_dir_name のどちらでもOK
      scope "characters/:character_ref" do
        get  "presence",                     to: "character_presence#show"
        post "transfer",                     to: "character_presence#transfer"
        post "utter",                        to: "character_actions#utter"
        post "action",                       to: "character_actions#action"
        post "conversation/boundary",         to: "character_actions#boundary"
      end
    end

    resources :characters, only: [:index, :show, :create, :update, :destroy] do
      post :chat, on: :member, to: "chats#create"
      post :reset, on: :member, to: "chats#reset"
      post :summarize, on: :member, to: "summarize#create"

      # 読書
      post  "reading/start",    to: "reading#start"
      post  "reading/continue", to: "reading#continue"
      get   "reading/current",  to: "reading#current"

      # 記憶想起
      post "memories/recall", to: "memories#recall"

      # ブランチ管理
      resources :branches, only: [:index, :create, :destroy], param: :name do
        post :checkout, on: :member
        post :merge, on: :member
      end

      # スナップショット
      resources :snapshots, only: [:index, :create] do
        post :restore, on: :collection
      end
    end

    get "aozora/search", to: "reading#search"

    resources :chat_results, only: [:show]
  end
end
