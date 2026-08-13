FactoryBot.define do
  factory :device do
    sequence(:name) { |n| "Device #{n}" }
    sequence(:slug) { |n| "test-device-#{n}" }
    capabilities { {} }
  end

  factory :device_key do
    device
    label { "test" }
    transient do
      plain_key { nil }
    end
    initialize_with do
      key = plain_key || "msdk_#{SecureRandom.urlsafe_base64(32)}"
      DeviceKey.new(
        device: device,
        key_hash: DeviceKey.hash_key(key),
        label: label,
      )
    end
  end

  factory :admin_key do
    label { "test" }
    transient do
      plain_key { nil }
    end
    initialize_with do
      key = plain_key || "msak_#{SecureRandom.urlsafe_base64(32)}"
      AdminKey.new(
        key_hash: AdminKey.hash_key(key),
        label: label,
      )
    end
  end

  factory :presence do
    character
  end

  factory :transfer do
    character
    to_device factory: :device
    occurred_at { Time.current }
    reason { "test" }
  end
end
