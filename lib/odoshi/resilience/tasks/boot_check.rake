# frozen_string_literal: true

namespace :boot do
  desc "Verify boot idempotency (DESIGN section 7): re-run config/initializers " \
       "in a forked child and fail on raise or class-level state drift"
  task check: :environment do
    ok = Odoshi::Resilience::BootCheck.run(Rails.application)
    abort("boot:check failed") unless ok
  end
end
