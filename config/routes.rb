Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check
  root "dashboard#index"
  get "guide", to: "guide#show", as: :guide
  resources :instruments, only: [:create, :update, :destroy, :show] do
    get :search, on: :collection
    post :refresh, on: :member
    patch :move, on: :member
    resources :price_levels, only: [:create, :destroy]
  end
  namespace :internal do
    get :watchlist, to: "feed#watchlist"
    post :ingest, to: "feed#ingest"
  end
end
