require "fileutils"
require "shellwords"

# Copied from: https://github.com/mattbrictson/rails-template
# Add this template directory to source_paths so that Thor actions like
# copy_file and template resolve against our source files. If this file was
# invoked remotely via HTTP, that means the files are not present locally.
# # In that case, use `git clone` to download them to a local temporary dir.
def add_template_repository_to_source_path
  sleep 5
  if __FILE__ =~ %r{\Ahttps?://}
    require "tmpdir"
    source_paths.unshift(tempdir = Dir.mktmpdir("rails7template"))
    sleep 5
    at_exit { FileUtils.remove_entry(tempdir) }
    git clone: [
      "--quiet",
      "https://github.com/bgvo/rails7-template.git",
      tempdir,
    ].map(&:shellescape).join(" ")

    if (branch = __FILE__[%r{jumpstart/(.+)/template.rb}, 1])
      Dir.chdir(tempdir) { git checkout: branch }
    end
  else
    source_paths.unshift(File.dirname(__FILE__))
  end
end

def rails_version
  @rails_version ||= Gem::Version.new(Rails::VERSION::STRING)
end

def rails_6_or_newer?
  Gem::Requirement.new(">= 6.0.0.alpha").satisfied_by? rails_version
end

def add_gems
  # Admin dashboard
  add_gem "administrate"

  # Notifications (email, Slack, Twillio, etc.)
  add_gem "noticed", "~> 1.4"

  # Pretend like you are another user
  add_gem "pretender", "~> 0.3.4"

  # Authorization and authentication
  add_gem "devise", "~> 4.9"
  add_gem "omniauth"
  add_gem "omniauth-google-oauth2"
  add_gem "pundit", "~> 2.1"

  # Payments
  add_gem "stripe", "~> 5.0"

  # Adds schema in models
  add_gem "annotate", group: :development

  # Formating
  add_gem "rufo", group: :development

  # Flip feature flags
  add_gem "flipper"

  # Open emails in the browser instead of sending them
  add_gem "letter_opener", group: :development
  add_gem "letter_opener_web", group: :development

  # Debugging
  add_gem "byebug", platforms: %i[ mri mingw x64_mingw ]
  add_gem "sentry-ruby"
  add_gem "sentry-rails"
  add_gem "sentry-sidekiq"
  add_gem "factory_bot_rails"
  add_gem "faker"

  # Other
  add_gem "friendly_id", "~> 5.4"
  add_gem "sidekiq", "~> 6.2"
  add_gem "sitemap_generator", "~> 6.1"
  add_gem "whenever", require: false
  add_gem "haml-rails"
  add_gem "html2haml"
end

def set_application_name
  # Add Application Name to Config
  environment "config.application_name = Rails.application.class.module_parent_name"

  # Announce the user where they can change the application name in the future.
  puts "You can change application name inside: ./config/application.rb"
end

def add_users
  route "root to: 'home#index'"
  generate "devise:install"

  environment "config.action_mailer.default_url_options = { host: 'localhost', port: 3000 }", env: "development"
  environment "config.action_mailer.delivery_method = :letter_opener", env: "development"

  generate :devise, "User", "first_name", "last_name", "admin:boolean"

  # Set admin default to false
  in_root do
    migration = Dir.glob("db/migrate/*").max_by { |f| File.mtime(f) }
    gsub_file migration, /:admin/, ":admin, default: false"
  end

  if Gem::Requirement.new("> 5.2").satisfied_by? rails_version
    gsub_file "config/initializers/devise.rb", /  # config.secret_key = .+/, "  config.secret_key = Rails.application.credentials.secret_key_base"
  end

  inject_into_file("app/models/user.rb", "omniauthable, :", after: "devise :")
end

def add_authorization
  generate "pundit:install"
end

def add_files
  create_file "Procfile", <<~YAML
                web: bundle exec rails server
                worker: bundle exec sidekiq
              YAML

  create_file "Procfile.dev", <<~YAML
                web: bundle exec rails server -p 3000
                worker: bundle exec sidekiq
              YAML

  route "get '/terms', to: 'home#terms'"
  route "get '/privacy', to: 'home#privacy'"

  copy_file "home_controller.rb", "app/controllers/home_controller.rb", force: true
  create_file "app/views/home/index.html.haml"
end

def add_sidekiq
  environment "config.active_job.queue_adapter = :sidekiq"

  insert_into_file "config/routes.rb",
    "require 'sidekiq/web'\n\n",
    before: "Rails.application.routes.draw do"

  content = <<~RUBY
    authenticate :user, lambda { |u| u.admin? } do
      mount Sidekiq::Web => '/sidekiq'
    end
  RUBY
  insert_into_file "config/routes.rb", "#{content}\n", after: "Rails.application.routes.draw do\n"
end

def add_notifications
  route "resources :notifications, only: [:index]"
end

def add_multiple_authentication
  insert_into_file "config/routes.rb", ', controllers: { omniauth_callbacks: "users/omniauth_callbacks" }', after: "  devise_for :users"

  generate "model Service user:references provider uid access_token access_token_secret refresh_token expires_at:datetime auth:text"

  template = "" "
  env_creds = Rails.application.credentials[Rails.env.to_sym] || {}
  %i{ google }.each do |provider|
    if options = env_creds[provider]
      config.omniauth provider, options[:app_id], options[:app_secret], options.fetch(:options, {})
    end
  end
  " "".strip

  insert_into_file "config/initializers/devise.rb", "  " + template + "\n\n", before: "  # ==> Warden configuration"
end

def add_whenever
  run "wheneverize ."
end

def add_friendly_id
  generate "friendly_id"
  # insert_into_file(Dir["db/migrate/**/*friendly_id_slugs.rb"].first, "[5.2]", after: "ActiveRecord::Migration")
end

def add_sitemap
  rails_command "sitemap:install"
end

def add_haml
  ENV["HAML_RAILS_DELETE_ERB"] = "true"
  rails_command "haml:erb2haml"
end

def add_overmind
  create_file ".overmind.env"
  insert_into_file ".overmind.env", <<~RUBY
                     OVERMIND_PROCFILE=Procfile.dev
                     OVERMIND_PORT=3000
                   RUBY

  remove_file "bin/dev"
  create_file "bin/dev", <<~SH
                #!/usr/bin/env sh

                exec overmind start -f Procfile.dev
              SH
end

def add_gem(name, *options)
  gem(name, *options) unless gem_exists?(name)
end

def gem_exists?(name)
  IO.read("Gemfile") =~ /^\s*gem ['"]#{name}['"]/
end

unless rails_6_or_newer?
  puts "Please use Rails 6.0 or newer to create a Startapp application"
end

# Main setup
add_gems

after_bundle do
  add_template_repository_to_source_path
  set_application_name
  add_users
  add_authorization
  add_notifications
  add_multiple_authentication
  add_sidekiq
  add_friendly_id
  add_whenever
  add_sitemap
  add_overmind
  # add_files
  add_haml
  rails_command "active_storage:install"

  # Make sure Linux is in the Gemfile.lock for deploying
  run "bundle lock --add-platform x86_64-linux"

  add_files

  # Commit everything to git
  unless ENV["SKIP_GIT"]
    git :init
    git add: "."
    # git commit will fail if user.email is not configured
    begin
      git commit: %( -m 'Initial commit' )
    rescue StandardError => e
      puts e.message
    end
  end

  say
  say "App successfully created!", :blue
  say
  say "To get started with your new app:", :green
  say "  cd #{original_app_name}"
  say "  bin/dev"
end
