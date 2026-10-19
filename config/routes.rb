Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  root "dashboard#index"
  get "hints", to: "hints#index", as: :hints
  get "hints/latest", to: "hints#latest", as: :latest_hints
  get "statistics", to: "statistics#index", as: :statistics
  get "signals/latest", to: "signals#latest", as: :latest_signals
  resources :signals, only: [:show, :destroy]
  get "guide", to: "guide#show", as: :guide
  resources :instruments, only: [:create, :update, :destroy, :show] do
    get :search, on: :collection
    get :quote, on: :member
    get :events, on: :member
    post :refresh, on: :member
    patch :move, on: :member
    resources :price_levels, only: [:create, :update, :destroy]
  end
  namespace :internal do
    get :watchlist, to: "feed#watchlist"
    post :ingest, to: "feed#ingest"
  end
end
