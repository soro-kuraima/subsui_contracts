#[test_only]
module subsui_contracts::dapp_integration_tests;

use std::vector;
use subsui_contracts::subscriptions::{Self, SubscriptionTier, Subscription, SubscriptionRegistry};
use sui::clock;
use sui::coin;
use sui::object;
use sui::sui::SUI;
use sui::test_scenario as ts;

// Test addresses
const CREATOR: address = @0xCAFE;
const SUBSCRIBER: address = @0xDEAD;
const DAPP_OWNER: address = @0xFACE;

// Additional test addresses - using valid hex values
const CREATOR1: address = @0xCE01;
const CREATOR2: address = @0xCE02;

// Test constants
const TIER_PRICE: u64 = 100000000; // 0.1 SUI
const TIER_DURATION: u64 = 2592000; // 30 days in seconds

/// Helper to create a test tier and return its ID
fun create_test_tier(scenario: &mut ts::Scenario, creator: address): object::ID {
    // Create the tier and capture its ID
    ts::next_tx(scenario, creator);
    let tier_id: object::ID;
    {
        // Create a test clock
        let ctx = ts::ctx(scenario);
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        let title = b"Premium Tier";
        let description = b"Premium content access";
        let mut benefits = vector::empty<vector<u8>>();
        vector::push_back(&mut benefits, b"Premium videos");

        // Create tier and capture ID
        tier_id =
            subscriptions::create_subscription_tier_for_testing(
                TIER_PRICE,
                TIER_DURATION,
                title,
                description,
                benefits,
                &clock,
                ts::ctx(scenario),
            );

        clock::destroy_for_testing(clock);
    };

    // Return the tier ID
    tier_id
}

/// Simulate a dApp checking if a user has access to premium content
fun check_premium_access(
    scenario: &mut ts::Scenario,
    creator: address,
    user: address,
    expect_access: bool,
) {
    ts::next_tx(scenario, DAPP_OWNER);
    {
        let registry = ts::take_shared<SubscriptionRegistry>(scenario);

        // Create a test clock
        let ctx = ts::ctx(scenario);
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000); // Set to 1,000,000 seconds

        // This is how a dApp would check if a user has access
        let has_access = subscriptions::has_active_subscription(
            &registry,
            creator,
            user,
            &clock,
        );

        // Verify the result matches expectations
        assert!(has_access == expect_access, 0);

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
    };
}

/// Helper to subscribe to a tier and return the subscription ID
fun subscribe_to_tier(
    scenario: &mut ts::Scenario,
    tier_id: object::ID,
    subscriber: address,
    payment_amount: u64,
): object::ID {
    // Subscribe and capture the subscription ID
    ts::next_tx(scenario, subscriber);
    let sub_id: object::ID;
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(scenario);

        // Create a test clock
        let ctx = ts::ctx(scenario);
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        // Mint payment
        let payment = coin::mint_for_testing<SUI>(payment_amount, ts::ctx(scenario));

        // Subscribe and capture ID
        sub_id =
            subscriptions::subscribe_for_testing(
                &mut tier,
                payment,
                &mut registry,
                &clock,
                ts::ctx(scenario),
            );

        clock::destroy_for_testing(clock);
        ts::return_shared(tier);
        ts::return_shared(registry);
    };

    // Return the subscription ID
    sub_id
}

/// Test user journey through a dApp integration
#[test]
fun test_dapp_user_journey() {
    // Set up a test scenario
    let mut scenario = ts::begin(DAPP_OWNER);

    // Initialize the subscription module
    ts::next_tx(&mut scenario, @0x0);
    {
        subscriptions::init_for_testing(ts::ctx(&mut scenario));
    };

    // 1. Content creator creates a subscription tier
    let tier_id = create_test_tier(&mut scenario, CREATOR);

    // 2. dApp checks if user has access (should be false)
    check_premium_access(&mut scenario, CREATOR, SUBSCRIBER, false);

    // 3. User subscribes
    let sub_id = subscribe_to_tier(&mut scenario, tier_id, SUBSCRIBER, TIER_PRICE);

    // 4. dApp checks if user has access (should be true now)
    check_premium_access(&mut scenario, CREATOR, SUBSCRIBER, true);

    // 5. Time advances (simulated by creating a clock with future time in next steps)

    // 6. User renews subscription
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut subscription = ts::take_from_sender_by_id<Subscription>(&mut scenario, sub_id);
        let tier = ts::take_shared_by_id<SubscriptionTier>(&mut scenario, tier_id);

        // Create a test clock with a future time
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);
        let future_time = 1000000 * 1000 + (TIER_DURATION + 100) * 1000; // Just past expiration
        clock::set_for_testing(&mut clock, future_time);

        // Mint payment for renewal
        let payment = coin::mint_for_testing<SUI>(
            TIER_PRICE,
            ts::ctx(&mut scenario),
        );

        // Renew
        subscriptions::renew_subscription(
            &mut subscription,
            &tier,
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, subscription);
        ts::return_shared(tier);
    };

    // 7. dApp checks if user has access again (should be true after renewal)
    check_premium_access(&mut scenario, CREATOR, SUBSCRIBER, true);

    // 8. User cancels subscription
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut subscription = ts::take_from_sender_by_id<Subscription>(&mut scenario, sub_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&mut scenario);

        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Cancel with clock parameter
        subscriptions::cancel_subscription(
            &mut subscription,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);

        ts::return_to_sender(&scenario, subscription);
        ts::return_shared(registry);
    };

    // 9. dApp checks if user has access (should be false after cancellation)
    check_premium_access(&mut scenario, CREATOR, SUBSCRIBER, false);

    ts::end(scenario);
}

/// Test multiple users subscribing to the same creator
#[test]
fun test_multiple_subscribers() {
    // Set up a test scenario
    let mut scenario = ts::begin(CREATOR);

    // Initialize the subscription module
    ts::next_tx(&mut scenario, @0x0);
    {
        subscriptions::init_for_testing(ts::ctx(&mut scenario));
    };

    // Create a subscription tier
    let tier_id = create_test_tier(&mut scenario, CREATOR);

    // Define multiple subscribers
    let subscriber1 = @0xABC1;
    let subscriber2 = @0xABC2;
    let subscriber3 = @0xABC3;

    // First subscriber subscribes
    let _sub_id1 = subscribe_to_tier(&mut scenario, tier_id, subscriber1, TIER_PRICE);

    // Second subscriber subscribes
    let _sub_id2 = subscribe_to_tier(&mut scenario, tier_id, subscriber2, TIER_PRICE);

    // Check subscriber count
    ts::next_tx(&mut scenario, CREATOR);
    {
        let tier = ts::take_shared_by_id<SubscriptionTier>(&mut scenario, tier_id);
        assert!(subscriptions::get_tier_subscriber_count(&tier) == 2, 0);
        ts::return_shared(tier);
    };

    // Verify both subscribers have access
    check_premium_access(&mut scenario, CREATOR, subscriber1, true);
    check_premium_access(&mut scenario, CREATOR, subscriber2, true);

    // Verify non-subscriber doesn't have access
    check_premium_access(&mut scenario, CREATOR, subscriber3, false);

    ts::end(scenario);
}

/// Test a single user subscribing to multiple creators
#[test]
fun test_multiple_creator_subscriptions() {
    // Set up a test scenario
    let mut scenario = ts::begin(SUBSCRIBER);

    // Initialize the subscription module
    ts::next_tx(&mut scenario, @0x0);
    {
        subscriptions::init_for_testing(ts::ctx(&mut scenario));
    };

    // First creator creates a tier
    let tier1_id = create_test_tier(&mut scenario, CREATOR1);

    // Second creator creates a tier
    let tier2_id = create_test_tier(&mut scenario, CREATOR2);

    // Initially user has no subscriptions
    check_premium_access(&mut scenario, CREATOR1, SUBSCRIBER, false);
    check_premium_access(&mut scenario, CREATOR2, SUBSCRIBER, false);

    // Subscribe to first creator
    let _sub1_id = subscribe_to_tier(&mut scenario, tier1_id, SUBSCRIBER, TIER_PRICE);

    // Subscribe to second creator
    let _sub2_id = subscribe_to_tier(&mut scenario, tier2_id, SUBSCRIBER, TIER_PRICE);

    // Now user should have access to both creators
    check_premium_access(&mut scenario, CREATOR1, SUBSCRIBER, true);
    check_premium_access(&mut scenario, CREATOR2, SUBSCRIBER, true);

    ts::end(scenario);
}
