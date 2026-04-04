Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    resources :characters, only: [:index, :show, :create, :update, :destroy] do
      post :chat, on: :member, to: "chats#create"
      post :reset, on: :member, to: "chats#reset"
    end

    resources :chat_results, only: [:show]

    resources :pending_messages, only: [:index] do
      patch :read, on: :member
    end
  end
end
