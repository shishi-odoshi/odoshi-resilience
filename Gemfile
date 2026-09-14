# frozen_string_literal: true
source "https://rubygems.org"
gemspec

group :development, :test do
  gem "minitest", "~> 5.25"
  gem "rake", "~> 13.0"
  # json 3.0.x breaks ActiveSupport::JSON.decode on current Rails releases
  # (seen breaking Solid Queue in any fresh app — see odoshi-template notes).
  # Pin until Rails ships a fix, then remove.
  gem "json", "< 3.0"
end

group :test do
  # Test-only: real ActiveRecord pool exhaustion exercised by
  # test/active_record_instrumentation_test.rb. Never a runtime dependency.
  gem "activerecord", ">= 7.1"
  gem "sqlite3", ">= 1.7"
end
