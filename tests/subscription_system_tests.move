#[test_only]
module subsui_contracts::subscriptions_tests;

use std::string;
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
const ANOTHER_USER: address = @0xBEEF;

// Test constants
const TIER_PRICE: u64 = 100000000; // 0.1 SUI
const TIER_DURATION: u64 = 2592000; // 30 days in seconds

// Create test tier parameters
fun create_test_tier_params(): (vector<u8>, vector<u8>, vector<vector<u8>>) {
    let title = b"Premium Tier";
    let description = b"Access to exclusive content";
    let mut benefits = vector::empty<vector<u8>>();
    vector::push_back(&mut benefits, b"Exclusive videos");
    vector::push_back(&mut benefits, b"Premium support");

    (title, description, benefits)
}

// Scenario setup with registry
fun setup_scenario(): ts::Scenario {
    let mut scenario = ts::begin(CREATOR);

    // Initialize the subscription module
    {
        ts::next_tx(&mut scenario, @0x0);
        subscriptions::init_for_testing(ts::ctx(&mut scenario));
    };

    scenario
}

// Helper to create a test tier and return its ID
fun create_test_tier(scenario: &mut ts::Scenario): object::ID {
    // Create the tier and capture its ID
    ts::next_tx(scenario, CREATOR);
    let tier_id: object::ID;
    {
        let (title, description, benefits) = create_test_tier_params();

        let ctx = ts::ctx(scenario);
        let mut clock = clock::create_for_testing(ctx);
        // Set clock to a known time
        clock::set_for_testing(&mut clock, 1000000 * 1000); // 1,000,000 seconds in ms

        // Create the tier and capture its ID
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

    // Return the captured ID
    tier_id
}

// Helper to mint test coins
fun mint_sui(scenario: &mut ts::Scenario, amount: u64): coin::Coin<SUI> {
    ts::next_tx(scenario, @0x0);
    coin::mint_for_testing<SUI>(amount, ts::ctx(scenario))
}

// Helper to fast forward the clock
fun advance_time(scenario: &mut ts::Scenario, current_time: u64, seconds_to_advance: u64): u64 {
    // Return the new timestamp
    current_time + (seconds_to_advance * 1000)
}

// Helper to subscribe to a tier and return the subscription ID
// FIXED: Added subscriber parameter
// Helper to subscribe to a tier and return the subscription ID
// IMPORTANT: This function does NOT advance to the next transaction
fun subscribe_to_tier_in_current_tx(
    scenario: &mut ts::Scenario,
    tier_id: object::ID,
    payment_amount: u64,
): object::ID {
    // Use the current transaction context - don't call ts::next_tx
    let sub_id: object::ID;
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(scenario);
        let ctx = ts::ctx(scenario);

        // Create a test clock
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000); // Set to a known time

        // Mint payment
        let payment = mint_sui(scenario, payment_amount);

        // Subscribe and capture the ID
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

// The original helper function that advances to the next transaction
// Keep this for backward compatibility with tests that expect it
fun subscribe_to_tier(
    scenario: &mut ts::Scenario,
    tier_id: object::ID,
    subscriber: address,
    payment_amount: u64,
): object::ID {
    // Start a new transaction as the subscriber
    ts::next_tx(scenario, subscriber);

    // Call the version that doesn't advance transactions
    subscribe_to_tier_in_current_tx(scenario, tier_id, payment_amount)
}

/* ==== TEST CASES ==== */

#[test]
/// Test creating a subscription tier
fun test_create_tier() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Verify tier properties
    ts::next_tx(&mut scenario, CREATOR);
    {
        let tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);

        // Check tier properties
        assert!(subscriptions::get_tier_creator(&tier) == CREATOR, 0);
        assert!(subscriptions::get_tier_price(&tier) == TIER_PRICE, 0);
        assert!(subscriptions::get_tier_duration(&tier) == TIER_DURATION, 0);
        assert!(subscriptions::get_tier_title(&tier) == string::utf8(b"Premium Tier"), 0);
        assert!(subscriptions::get_tier_subscriber_count(&tier) == 0, 0);

        ts::return_shared(tier);
    };

    ts::end(scenario);
}

#[test]
/// Test updating a subscription tier
fun test_update_tier() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Update tier
    ts::next_tx(&mut scenario, CREATOR);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);

        // Update values
        let new_price = TIER_PRICE * 2;
        let new_duration = TIER_DURATION * 2;
        let new_title = b"Premium Plus Tier";
        let new_description = b"Enhanced premium access";
        let mut new_benefits = vector::empty<vector<u8>>();
        vector::push_back(&mut new_benefits, b"Everything in Premium");
        vector::push_back(&mut new_benefits, b"Super exclusive content");

        subscriptions::update_subscription_tier(
            &mut tier,
            new_price,
            new_duration,
            new_title,
            new_description,
            new_benefits,
            ts::ctx(&mut scenario),
        );

        // Verify updated values
        assert!(subscriptions::get_tier_price(&tier) == new_price, 0);
        assert!(subscriptions::get_tier_duration(&tier) == new_duration, 0);
        assert!(subscriptions::get_tier_title(&tier) == string::utf8(new_title), 0);

        ts::return_shared(tier);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = subscriptions::ENotTierCreator)]
/// Test that only the creator can update a tier
fun test_update_tier_unauthorized() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Try to update tier as non-creator
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);

        let (title, description, benefits) = create_test_tier_params();

        // This should fail
        subscriptions::update_subscription_tier(
            &mut tier,
            TIER_PRICE * 2,
            TIER_DURATION,
            title,
            description,
            benefits,
            ts::ctx(&mut scenario),
        );

        ts::return_shared(tier);
    };

    ts::end(scenario);
}

#[test]
/// Test subscribing to a tier
fun test_subscribe() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Check initial tier subscriber count
    ts::next_tx(&mut scenario, CREATOR);
    {
        let tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        assert!(subscriptions::get_tier_subscriber_count(&tier) == 0, 0);
        ts::return_shared(tier);
    };

    // Subscribe using the working pattern from dapp tests
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        // Create a test clock
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        // Mint payment
        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Subscribe directly (don't use our helper)
        subscriptions::subscribe_for_testing(
            &mut tier,
            payment,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(tier);
        ts::return_shared(registry);
    };

    // Check tier subscriber count after subscribing
    ts::next_tx(&mut scenario, CREATOR);
    {
        let tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        assert!(subscriptions::get_tier_subscriber_count(&tier) == 1, 0);
        ts::return_shared(tier);
    };

    // Check if subscription is active using registry
    ts::next_tx(&mut scenario, @0x0);
    {
        let registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Verify subscriber has active subscription
        assert!(
            subscriptions::has_active_subscription(
                &registry,
                CREATOR,
                SUBSCRIBER,
                &clock,
            ),
            0,
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = subscriptions::EInsufficientFunds)]
/// Test subscribing with insufficient funds
fun test_subscribe_insufficient_funds() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Try to subscribe with insufficient payment - FIXED: Added SUBSCRIBER parameter
    let insufficient_amount = TIER_PRICE - 1;
    let _sub_id = subscribe_to_tier(&mut scenario, tier_id, SUBSCRIBER, insufficient_amount);

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = subscriptions::ESubscriptionAlreadyActive)]
/// Test that a user cannot subscribe twice to the same creator
fun test_subscribe_already_active() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe first time - FIXED: Added SUBSCRIBER parameter
    let _sub_id = subscribe_to_tier(&mut scenario, tier_id, SUBSCRIBER, TIER_PRICE);

    // Try to subscribe again - FIXED: Added SUBSCRIBER parameter
    let _sub_id2 = subscribe_to_tier(&mut scenario, tier_id, SUBSCRIBER, TIER_PRICE);

    ts::end(scenario);
}

#[test]
/// Test renewing a subscription
fun test_renew_subscription() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Subscribe
        subscriptions::subscribe_for_testing(
            &mut tier,
            payment,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(tier);
        ts::return_shared(registry);
    };

    // Get the subscription object and renew it
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        // Find all subscriptions owned by SUBSCRIBER
        let objects = ts::ids_for_sender<Subscription>(&scenario);
        assert!(vector::length(&objects) == 1, 0); // Should have exactly one subscription

        let sub_id = *vector::borrow(&objects, 0);
        let mut subscription = ts::take_from_sender_by_id<Subscription>(&scenario, sub_id);
        let tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);

        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000); // Initial time

        // Get initial end time
        let (_, _, _, initial_end_time, _) = subscriptions::get_subscription_details(&subscription);

        // Create payment for renewal
        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Renew subscription
        subscriptions::renew_subscription(
            &mut subscription,
            &tier,
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        // Verify new end time is extended
        let (_, _, _, new_end_time, _) = subscriptions::get_subscription_details(&subscription);
        assert!(new_end_time == initial_end_time + TIER_DURATION, 0);

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, subscription);
        ts::return_shared(tier);
    };

    ts::end(scenario);
}

#[test]
/// Test renewing an expired subscription
fun test_renew_expired_subscription() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Subscribe
        subscriptions::subscribe_for_testing(
            &mut tier,
            payment,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(tier);
        ts::return_shared(registry);
    };

    // Get the subscription object and renew it after expiration
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        // Find all subscriptions owned by SUBSCRIBER
        let objects = ts::ids_for_sender<Subscription>(&scenario);
        assert!(vector::length(&objects) == 1, 0); // Should have exactly one subscription

        let sub_id = *vector::borrow(&objects, 0);
        let mut subscription = ts::take_from_sender_by_id<Subscription>(&scenario, sub_id);
        let tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);

        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Set time to after expiration
        let expired_time = (1000000 + TIER_DURATION + 1000) * 1000;
        clock::set_for_testing(&mut clock, expired_time);

        // Verify subscription is expired
        assert!(!subscriptions::is_subscription_active(&subscription, &clock), 0);

        // Create payment for renewal
        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Renew subscription
        subscriptions::renew_subscription(
            &mut subscription,
            &tier,
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        // Verify new end time starts from current time
        let (_, _, _, new_end_time, _) = subscriptions::get_subscription_details(&subscription);
        assert!(new_end_time == expired_time / 1000 + TIER_DURATION, 0);

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, subscription);
        ts::return_shared(tier);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure]
/// Test that only the owner can renew a subscription
fun test_renew_unauthorized() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe - FIXED: Added SUBSCRIBER parameter
    let sub_id = subscribe_to_tier(&mut scenario, tier_id, SUBSCRIBER, TIER_PRICE);

    // Test setup: Share the subscription object
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let subscription = ts::take_from_sender_by_id<Subscription>(&scenario, sub_id);
        ts::return_shared(subscription);
    };

    // Try to renew as non-owner (will fail)
    ts::next_tx(&mut scenario, ANOTHER_USER);
    {
        let mut subscription = ts::take_shared_by_id<Subscription>(&scenario, sub_id);
        let tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);

        // Create a test clock
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Mint payment
        let payment = mint_sui(&mut scenario, TIER_PRICE);

        // Try to renew (should fail)
        subscriptions::renew_subscription(
            &mut subscription,
            &tier,
            payment,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(subscription);
        ts::return_shared(tier);
    };

    ts::end(scenario);
}

#[test]
/// Test setting auto-renew flag
fun test_set_auto_renew() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Subscribe
        subscriptions::subscribe_for_testing(
            &mut tier,
            payment,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(tier);
        ts::return_shared(registry);
    };

    // Get the subscription object and set auto-renew
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        // Find all subscriptions owned by SUBSCRIBER
        let objects = ts::ids_for_sender<Subscription>(&scenario);
        assert!(vector::length(&objects) == 1, 0); // Should have exactly one subscription

        let sub_id = *vector::borrow(&objects, 0);
        let mut subscription = ts::take_from_sender_by_id<Subscription>(&scenario, sub_id);

        // Initially should be false
        let (_, _, _, _, auto_renew) = subscriptions::get_subscription_details(&subscription);
        assert!(!auto_renew, 0);

        // Set to true
        subscriptions::set_auto_renew(&mut subscription, true, ts::ctx(&mut scenario));

        // Verify it's now true
        let (_, _, _, _, new_auto_renew) = subscriptions::get_subscription_details(&subscription);
        assert!(new_auto_renew, 0);

        ts::return_to_sender(&scenario, subscription);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure]
/// Test that only the owner can set auto-renew
fun test_set_auto_renew_unauthorized() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe - FIXED: Added SUBSCRIBER parameter
    let sub_id = subscribe_to_tier(&mut scenario, tier_id, SUBSCRIBER, TIER_PRICE);

    // Test setup: Share the subscription object
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let subscription = ts::take_from_sender_by_id<Subscription>(&scenario, sub_id);
        ts::return_shared(subscription);
    };

    // Try to set auto-renew as non-owner (will fail)
    ts::next_tx(&mut scenario, ANOTHER_USER);
    {
        let mut subscription = ts::take_shared_by_id<Subscription>(&scenario, sub_id);

        // Try to set auto-renew (should fail)
        subscriptions::set_auto_renew(&mut subscription, true, ts::ctx(&mut scenario));

        ts::return_shared(subscription);
    };

    ts::end(scenario);
}

#[test]
/// Test canceling a subscription
fun test_cancel_subscription() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe directly
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Subscribe
        subscriptions::subscribe_for_testing(
            &mut tier,
            payment,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(tier);
        ts::return_shared(registry);
    };

    // Verify subscription is active
    ts::next_tx(&mut scenario, @0x0);
    {
        let registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        assert!(
            subscriptions::has_active_subscription(
                &registry,
                CREATOR,
                SUBSCRIBER,
                &clock,
            ),
            0,
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
    };

    // Get the subscription object for cancellation
    // We need to enumerate all objects owned by SUBSCRIBER to find it
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        // Find all subscriptions owned by SUBSCRIBER
        let objects = ts::ids_for_sender<Subscription>(&scenario);
        assert!(vector::length(&objects) == 1, 0); // Should have exactly one subscription

        let sub_id = *vector::borrow(&objects, 0);
        let mut subscription = ts::take_from_sender_by_id<Subscription>(&scenario, sub_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);

        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Cancel subscription
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

    // Verify subscription is now inactive
    ts::next_tx(&mut scenario, @0x0);
    {
        let registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        assert!(
            !subscriptions::has_active_subscription(
                &registry,
                CREATOR,
                SUBSCRIBER,
                &clock,
            ),
            0,
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure]
/// Test that only the owner can cancel a subscription
fun test_cancel_subscription_unauthorized() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe - FIXED: Added SUBSCRIBER parameter
    let sub_id = subscribe_to_tier(&mut scenario, tier_id, SUBSCRIBER, TIER_PRICE);

    // Test setup: Share the subscription object
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let subscription = ts::take_from_sender_by_id<Subscription>(&scenario, sub_id);
        ts::return_shared(subscription);
    };

    // Try to cancel as non-owner (will fail)
    ts::next_tx(&mut scenario, ANOTHER_USER);
    {
        let mut subscription = ts::take_shared_by_id<Subscription>(&scenario, sub_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);

        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Try to cancel with clock parameter
        subscriptions::cancel_subscription(
            &mut subscription,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);

        ts::return_shared(subscription);
        ts::return_shared(registry);
    };

    ts::end(scenario);
}

#[test]
/// Test is_subscription_active function
fun test_is_subscription_active() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Subscribe
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Subscribe
        subscriptions::subscribe_for_testing(
            &mut tier,
            payment,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(tier);
        ts::return_shared(registry);
    };

    // Get the subscription object and check if it's active
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        // Find all subscriptions owned by SUBSCRIBER
        let objects = ts::ids_for_sender<Subscription>(&scenario);
        assert!(vector::length(&objects) == 1, 0); // Should have exactly one subscription

        let sub_id = *vector::borrow(&objects, 0);
        let subscription = ts::take_from_sender_by_id<Subscription>(&scenario, sub_id);

        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000); // Initial time

        // Should be active
        assert!(subscriptions::is_subscription_active(&subscription, &clock), 0);

        // Change time to expired
        clock::set_for_testing(&mut clock, (1000000 + TIER_DURATION + 1000) * 1000);

        // Should no longer be active
        assert!(!subscriptions::is_subscription_active(&subscription, &clock), 0);

        clock::destroy_for_testing(clock);
        ts::return_to_sender(&scenario, subscription);
    };

    ts::end(scenario);
}

#[test]
/// Test has_active_subscription function
fun test_has_active_subscription() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Check before subscribing
    ts::next_tx(&mut scenario, @0x0);
    {
        let registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Should not have an active subscription
        assert!(
            !subscriptions::has_active_subscription(
                &registry,
                CREATOR,
                SUBSCRIBER,
                &clock,
            ),
            0,
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
    };

    // Subscribe
    ts::next_tx(&mut scenario, SUBSCRIBER);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        let mut registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);

        let mut clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut clock, 1000000 * 1000);

        let payment = coin::mint_for_testing<SUI>(TIER_PRICE, ctx);

        // Subscribe
        subscriptions::subscribe_for_testing(
            &mut tier,
            payment,
            &mut registry,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(tier);
        ts::return_shared(registry);
    };

    // Check after subscribing
    ts::next_tx(&mut scenario, @0x0);
    {
        let registry = ts::take_shared<SubscriptionRegistry>(&scenario);
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Should have an active subscription
        assert!(
            subscriptions::has_active_subscription(
                &registry,
                CREATOR,
                SUBSCRIBER,
                &clock,
            ),
            0,
        );

        clock::destroy_for_testing(clock);
        ts::return_shared(registry);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = subscriptions::EInvalidPrice)]
/// Test invalid tier price (zero)
fun test_create_tier_invalid_price() {
    let mut scenario = setup_scenario();

    ts::next_tx(&mut scenario, CREATOR);
    {
        let (title, description, benefits) = create_test_tier_params();

        // Create a test clock
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Create tier with invalid price (0)
        subscriptions::create_subscription_tier(
            0, // Invalid price
            TIER_DURATION,
            title,
            description,
            benefits,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = subscriptions::EInvalidDuration)]
/// Test invalid tier duration (zero)
fun test_create_tier_invalid_duration() {
    let mut scenario = setup_scenario();

    ts::next_tx(&mut scenario, CREATOR);
    {
        let (title, description, benefits) = create_test_tier_params();

        // Create a test clock
        let ctx = ts::ctx(&mut scenario);
        let mut clock = clock::create_for_testing(ctx);

        // Create tier with invalid duration (0)
        subscriptions::create_subscription_tier(
            TIER_PRICE,
            0, // Invalid duration
            title,
            description,
            benefits,
            &clock,
            ts::ctx(&mut scenario),
        );

        clock::destroy_for_testing(clock);
    };

    ts::end(scenario);
}

#[test]
/// Test partial tier updates
fun test_partial_tier_update() {
    let mut scenario = setup_scenario();

    // Create tier
    let tier_id = create_test_tier(&mut scenario);

    // Update just the price
    ts::next_tx(&mut scenario, CREATOR);
    {
        let mut tier = ts::take_shared_by_id<SubscriptionTier>(&scenario, tier_id);
        let original_title = subscriptions::get_tier_title(&tier);

        // Update only price, leave other fields as empty vectors
        let empty_bytes = vector::empty<u8>();
        let empty_benefits = vector::empty<vector<u8>>();

        subscriptions::update_subscription_tier(
            &mut tier,
            TIER_PRICE * 2,
            0, // Don't update duration
            empty_bytes, // Don't update title
            empty_bytes, // Don't update description
            empty_benefits, // Don't update benefits
            ts::ctx(&mut scenario),
        );

        // Verify only price changed
        assert!(subscriptions::get_tier_price(&tier) == TIER_PRICE * 2, 0);
        assert!(subscriptions::get_tier_duration(&tier) == TIER_DURATION, 0);
        assert!(subscriptions::get_tier_title(&tier) == original_title, 0);

        ts::return_shared(tier);
    };

    ts::end(scenario);
}
