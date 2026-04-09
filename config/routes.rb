Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
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
