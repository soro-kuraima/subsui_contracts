module subsui_contracts::subscriptions;

use std::string::{Self, String};
use std::vector;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// Error codes
const EInvalidPrice: u64 = 0;
const EInsufficientFunds: u64 = 1;
const EInvalidDuration: u64 = 2;
const ENotSubscriptionOwner: u64 = 3;
const ENotTierCreator: u64 = 5;
const ESubscriptionAlreadyActive: u64 = 6;

// Represents a subscription tier created by a content creator
public struct SubscriptionTier has key, store {
    id: UID,
    creator: address,
    price: u64, // In SUI, smallest denomination
    duration: u64, // In seconds
    title: String,
    description: String,
    benefits: vector<String>,
    subscriber_count: u64,
    created_at: u64,
}

// Represents an active subscription owned by a subscriber
public struct Subscription has key, store {
    id: UID,
    tier_id: ID,
    subscriber: address,
    creator: address,
    start_time: u64, // Timestamp in seconds
    end_time: u64, // Timestamp in seconds
    price_paid: u64, // Amount paid in SUI
    auto_renew: bool, // Whether to auto-renew (requires off-chain trigger)
}

// Key for accessing creator's subscription info in the registry
public struct CreatorKey has copy, drop, store {
    creator: address,
    subscriber: address,
}

// Global registry for finding subscriptions without direct object references
public struct SubscriptionRegistry has key {
    id: UID,
    // Maps CreatorKey to Subscription ID
    subscriptions: Table<CreatorKey, ID>,
}

// Events
public struct TierCreated has copy, drop {
    tier_id: ID,
    creator: address,
    price: u64,
    duration: u64,
    title: String,
}

public struct SubscriptionCreated has copy, drop {
    subscription_id: ID,
    tier_id: ID,
    subscriber: address,
    creator: address,
    end_time: u64,
}

public struct SubscriptionRenewed has copy, drop {
    subscription_id: ID,
    subscriber: address,
    creator: address,
    new_end_time: u64,
}

public struct SubscriptionCancelled has copy, drop {
    subscription_id: ID,
    subscriber: address,
    creator: address,
}

// Initialize the module
fun init(ctx: &mut TxContext) {
    // Create and share the global subscription registry
    let registry = SubscriptionRegistry {
        id: object::new(ctx),
        subscriptions: table::new(ctx),
    };
    transfer::share_object(registry);
}

// === Creator Functions ===

// Create a new subscription tier
public entry fun create_subscription_tier(
    price: u64,
    duration: u64,
    title: vector<u8>,
    description: vector<u8>,
    benefits: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate inputs
    assert!(price > 0, EInvalidPrice);
    assert!(duration > 0, EInvalidDuration);

    // Convert vector<u8> to String
    let title_str = string::utf8(title);
    let description_str = string::utf8(description);
    let mut benefits_str = vector::empty<String>();

    // Convert benefits to String vector
    let mut i = 0;
    let len = vector::length(&benefits);
    while (i < len) {
        let benefit = vector::borrow(&benefits, i);
        vector::push_back(&mut benefits_str, string::utf8(*benefit));
        i = i + 1;
    };

    // Create the subscription tier object
    let tier = SubscriptionTier {
        id: object::new(ctx),
        creator: tx_context::sender(ctx),
        price,
        duration,
        title: title_str,
        description: description_str,
        benefits: benefits_str,
        subscriber_count: 0,
        created_at: clock::timestamp_ms(clock) / 1000, // Convert ms to seconds
    };

    // Emit event
    event::emit(TierCreated {
        tier_id: object::id(&tier),
        creator: tx_context::sender(ctx),
        price,
        duration,
        title: title_str,
    });

    // Transfer the tier object to the creator
    transfer::public_share_object(tier);
}

// Update a subscription tier
public entry fun update_subscription_tier(
    tier: &mut SubscriptionTier,
    price: u64,
    duration: u64,
    title: vector<u8>,
    description: vector<u8>,
    benefits: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    // Verify the sender is the tier creator
    assert!(tier.creator == tx_context::sender(ctx), ENotTierCreator);

    // Update tier details
    if (price > 0) {
        tier.price = price;
    };

    if (duration > 0) {
        tier.duration = duration;
    };

    if (vector::length(&title) > 0) {
        tier.title = string::utf8(title);
    };

    if (vector::length(&description) > 0) {
        tier.description = string::utf8(description);
    };

    if (vector::length(&benefits) > 0) {
        // Clear existing benefits
        tier.benefits = vector::empty();

        // Add new benefits
        let mut i = 0;
        let len = vector::length(&benefits);
        while (i < len) {
            let benefit = vector::borrow(&benefits, i);
            vector::push_back(&mut tier.benefits, string::utf8(*benefit));
            i = i + 1;
        };
    };
}

// === Subscriber Functions ===

// Subscribe to a tier
public entry fun subscribe(
    tier: &mut SubscriptionTier,
    payment: Coin<SUI>,
    registry: &mut SubscriptionRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let payment_amount = coin::value(&payment);

    // Verify payment is sufficient
    assert!(payment_amount >= tier.price, EInsufficientFunds);

    // Create the subscription
    let subscriber = tx_context::sender(ctx);
    let creator = tier.creator;
    let now = clock::timestamp_ms(clock) / 1000; // Convert ms to seconds
    let end_time = now + tier.duration;

    // Create the registry key
    let key = CreatorKey {
        creator: creator,
        subscriber: subscriber,
    };

    // Check if subscription already exists
    if (table::contains(&registry.subscriptions, key)) {
        // Existing subscription - return payment
        transfer::public_transfer(payment, subscriber);
        abort ESubscriptionAlreadyActive
    };

    // Create subscription object
    let subscription = Subscription {
        id: object::new(ctx),
        tier_id: object::id(tier),
        subscriber: subscriber,
        creator: creator,
        start_time: now,
        end_time: end_time,
        price_paid: tier.price,
        auto_renew: false,
    };

    // Record in registry
    table::add(&mut registry.subscriptions, key, object::id(&subscription));

    // Update subscriber count
    tier.subscriber_count = tier.subscriber_count + 1;

    // Transfer payment to creator
    transfer::public_transfer(payment, creator);

    // Emit event
    event::emit(SubscriptionCreated {
        subscription_id: object::id(&subscription),
        tier_id: object::id(tier),
        subscriber: subscriber,
        creator: creator,
        end_time: end_time,
    });

    // Transfer subscription to subscriber
    transfer::transfer(subscription, subscriber);
}

// Renew an existing subscription
public entry fun renew_subscription(
    subscription: &mut Subscription,
    tier: &SubscriptionTier,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify ownership
    assert!(subscription.subscriber == tx_context::sender(ctx), ENotSubscriptionOwner);

    // Verify sufficient payment
    assert!(coin::value(&payment) >= tier.price, EInsufficientFunds);

    // Verify tier matches
    assert!(subscription.tier_id == object::id(tier), 0);

    let now = clock::timestamp_ms(clock) / 1000;

    // If subscription has expired, start from now
    // If still active, extend from previous end date
    let new_end_time = if (subscription.end_time < now) {
        now + tier.duration
    } else {
        subscription.end_time + tier.duration
    };

    // Update subscription
    subscription.end_time = new_end_time;
    subscription.price_paid = subscription.price_paid + tier.price;

    // Transfer payment to creator
    transfer::public_transfer(payment, subscription.creator);

    // Emit event
    event::emit(SubscriptionRenewed {
        subscription_id: object::id(subscription),
        subscriber: subscription.subscriber,
        creator: subscription.creator,
        new_end_time: new_end_time,
    });
}

// Enable or disable auto-renewal
public entry fun set_auto_renew(
    subscription: &mut Subscription,
    auto_renew: bool,
    ctx: &mut TxContext,
) {
    // Verify ownership
    assert!(subscription.subscriber == tx_context::sender(ctx), ENotSubscriptionOwner);

    // Update auto-renew setting
    subscription.auto_renew = auto_renew;
}

// Cancel a subscription
public entry fun cancel_subscription(
    subscription: &mut Subscription,
    registry: &mut SubscriptionRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify ownership
    assert!(subscription.subscriber == tx_context::sender(ctx), ENotSubscriptionOwner);

    // Create the registry key
    let key = CreatorKey {
        creator: subscription.creator,
        subscriber: subscription.subscriber,
    };

    // Remove from registry
    if (table::contains(&registry.subscriptions, key)) {
        table::remove(&mut registry.subscriptions, key);
    };

    // Emit event
    event::emit(SubscriptionCancelled {
        subscription_id: object::id(subscription),
        subscriber: subscription.subscriber,
        creator: subscription.creator,
    });

    // Set auto_renew to false
    subscription.auto_renew = false;

    // Set end_time to now (effectively canceling it immediately)
    subscription.end_time = clock::timestamp_ms(clock) / 1000;
}

// === Query Functions ===

// Check if a subscription is active
public fun is_subscription_active(subscription: &Subscription, clock: &Clock): bool {
    let now = clock::timestamp_ms(clock) / 1000;
    subscription.end_time > now
}

// Check if user has active subscription to a creator
public fun has_active_subscription(
    registry: &SubscriptionRegistry,
    creator: address,
    subscriber: address,
    clock: &Clock,
): bool {
    let key = CreatorKey {
        creator: creator,
        subscriber: subscriber,
    };

    if (!table::contains(&registry.subscriptions, key)) {
        return false
    };

    // Get the subscription ID, but we don't use it in this simplified version
    let _sub_id = *table::borrow(&registry.subscriptions, key);

    // For this example, we'll assume all entries in the registry are active
    // A full implementation would verify end_time > now
    true
}

// Get subscription details
public fun get_subscription_details(
    subscription: &Subscription,
): (address, address, u64, u64, bool) {
    (
        subscription.subscriber,
        subscription.creator,
        subscription.start_time,
        subscription.end_time,
        subscription.auto_renew,
    )
}

// Get tier details
public fun get_tier_details(tier: &SubscriptionTier): (address, u64, u64, String, u64) {
    (tier.creator, tier.price, tier.duration, tier.title, tier.subscriber_count)
}

#[test_only]
/// Initialize the module for testing
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

/// Get creator from a tier - accessor method
public fun get_tier_creator(tier: &SubscriptionTier): address {
    tier.creator
}

/// Get price from a tier - accessor method
public fun get_tier_price(tier: &SubscriptionTier): u64 {
    tier.price
}

/// Get duration from a tier - accessor method
public fun get_tier_duration(tier: &SubscriptionTier): u64 {
    tier.duration
}

/// Get title from a tier - accessor method
public fun get_tier_title(tier: &SubscriptionTier): String {
    tier.title
}

/// Get subscriber count from a tier - accessor method
public fun get_tier_subscriber_count(tier: &SubscriptionTier): u64 {
    tier.subscriber_count
}

#[test_only]
/// Create a subscription tier and return its ID for testing
public fun create_subscription_tier_for_testing(
    price: u64,
    duration: u64,
    title: vector<u8>,
    description: vector<u8>,
    benefits: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    // Convert to strings
    let title_str = string::utf8(title);
    let description_str = string::utf8(description);
    let mut benefits_str = vector::empty<String>();

    // Convert benefits
    let mut i = 0;
    let len = vector::length(&benefits);
    while (i < len) {
        let benefit = vector::borrow(&benefits, i);
        vector::push_back(&mut benefits_str, string::utf8(*benefit));
        i = i + 1;
    };

    // Create the tier object
    let tier = SubscriptionTier {
        id: object::new(ctx),
        creator: tx_context::sender(ctx),
        price,
        duration,
        title: title_str,
        description: description_str,
        benefits: benefits_str,
        subscriber_count: 0,
        created_at: clock::timestamp_ms(clock) / 1000,
    };

    // Get the ID before transferring
    let tier_id = object::id(&tier);

    // Emit event
    event::emit(TierCreated {
        tier_id,
        creator: tx_context::sender(ctx),
        price,
        duration,
        title: title_str,
    });

    // Share the tier object
    transfer::public_share_object(tier);

    // Return the actual ID
    tier_id
}

#[test_only]
/// Subscribe to a tier and return the subscription ID for testing
public fun subscribe_for_testing(
    tier: &mut SubscriptionTier,
    payment: Coin<SUI>,
    registry: &mut SubscriptionRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let payment_amount = coin::value(&payment);

    // Verify payment is sufficient
    assert!(payment_amount >= tier.price, EInsufficientFunds);

    // Create the subscription
    let subscriber = tx_context::sender(ctx);
    let creator = tier.creator;
    let now = clock::timestamp_ms(clock) / 1000;
    let end_time = now + tier.duration;

    // Create the registry key
    let key = CreatorKey {
        creator,
        subscriber,
    };

    // Check if subscription already exists
    if (table::contains(&registry.subscriptions, key)) {
        transfer::public_transfer(payment, subscriber);
        abort ESubscriptionAlreadyActive
    };

    // Create subscription object
    let subscription = Subscription {
        id: object::new(ctx),
        tier_id: object::id(tier),
        subscriber,
        creator,
        start_time: now,
        end_time,
        price_paid: tier.price,
        auto_renew: false,
    };

    // Get the ID before transferring
    let subscription_id = object::id(&subscription);

    // Record in registry
    table::add(&mut registry.subscriptions, key, subscription_id);

    // Update subscriber count
    tier.subscriber_count = tier.subscriber_count + 1;

    // Transfer payment to creator
    transfer::public_transfer(payment, creator);

    // Emit event
    event::emit(SubscriptionCreated {
        subscription_id,
        tier_id: object::id(tier),
        subscriber,
        creator,
        end_time,
    });

    // Transfer subscription to subscriber
    transfer::transfer(subscription, subscriber);

    // Return the actual ID
    subscription_id
}
