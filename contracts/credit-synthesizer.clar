;; =============================================================================
;; CREDIT SYNTHESIZER - SYNTHETIC CREDIT DERIVATIVES PLATFORM
;; =============================================================================
;; Create synthetic credit derivatives tracking real-world loan performance
;; Manage collateral for synthetic positions, handle liquidations and margin calls
;; Provide credit risk exposure without direct lending
;; Enable credit portfolio diversification

;; =============================================================================
;; ERROR CODES
;; =============================================================================

(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_POSITION (err u101))
(define-constant ERR_INSUFFICIENT_COLLATERAL (err u102))
(define-constant ERR_POSITION_NOT_FOUND (err u103))
(define-constant ERR_LIQUIDATION_NOT_ALLOWED (err u104))
(define-constant ERR_INVALID_AMOUNT (err u105))
(define-constant ERR_POSITION_ALREADY_EXISTS (err u106))
(define-constant ERR_CREDIT_ASSET_NOT_FOUND (err u107))
(define-constant ERR_INSUFFICIENT_BALANCE (err u108))
(define-constant ERR_INVALID_RATIO (err u109))
(define-constant ERR_ORACLE_ERROR (err u110))

;; =============================================================================
;; CONSTANTS
;; =============================================================================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant LIQUIDATION_THRESHOLD u8000) ;; 80% collateral ratio
(define-constant MIN_COLLATERAL_RATIO u12000) ;; 120% minimum collateral ratio
(define-constant LIQUIDATION_PENALTY u500) ;; 5% liquidation penalty
(define-constant PRECISION u10000) ;; 100.00% = 10000
(define-constant MAX_POSITIONS u1000)

;; =============================================================================
;; DATA STRUCTURES
;; =============================================================================

;; Credit asset information
(define-map credit-assets
  { asset-id: uint }
  {
    name: (string-ascii 64),
    symbol: (string-ascii 16),
    price: uint,
    credit-rating: uint, ;; 1-10 scale (10 = AAA, 1 = D)
    default-probability: uint, ;; basis points (100 = 1%)
    maturity: uint, ;; block height
    total-supply: uint,
    active: bool
  }
)

;; Synthetic credit positions
(define-map positions
  { position-id: uint }
  {
    owner: principal,
    asset-id: uint,
    synthetic-amount: uint, ;; amount of synthetic tokens
    collateral-amount: uint, ;; STX collateral deposited
    collateral-ratio: uint, ;; current collateral ratio (basis points)
    entry-price: uint, ;; price when position was opened
    liquidation-price: uint, ;; price at which position gets liquidated
    created-at: uint, ;; block height
    last-updated: uint, ;; block height
    active: bool
  }
)

;; User position tracking
(define-map user-positions
  { user: principal }
  { position-ids: (list 100 uint) }
)

;; Collateral tracking
(define-map collateral-balances
  { user: principal }
  { balance: uint }
)

;; Position liquidation queue
(define-map liquidation-queue
  { position-id: uint }
  {
    liquidation-price: uint,
    liquidation-block: uint,
    liquidator: (optional principal)
  }
)

;; =============================================================================
;; DATA VARIABLES
;; =============================================================================

(define-data-var next-asset-id uint u1)
(define-data-var next-position-id uint u1)
(define-data-var total-positions uint u0)
(define-data-var total-collateral uint u0)
(define-data-var protocol-fees uint u0)
(define-data-var oracle-address (optional principal) none)
(define-data-var emergency-shutdown bool false)

;; =============================================================================
;; PRIVATE FUNCTIONS
;; =============================================================================

;; Calculate collateral ratio for a position
(define-private (calculate-collateral-ratio (collateral-amount uint) (synthetic-amount uint) (asset-price uint))
  (if (is-eq synthetic-amount u0)
    u0
    (/ (* collateral-amount PRECISION) (* synthetic-amount asset-price))
  )
)

;; Calculate liquidation price for a position
(define-private (calculate-liquidation-price (collateral-amount uint) (synthetic-amount uint))
  (if (is-eq synthetic-amount u0)
    u0
    (/ (* collateral-amount PRECISION) (* synthetic-amount LIQUIDATION_THRESHOLD))
  )
)

;; Validate collateral ratio meets minimum requirements
(define-private (validate-collateral-ratio (ratio uint))
  (>= ratio MIN_COLLATERAL_RATIO)
)

;; Update position health metrics
(define-private (update-position-health (position-id uint) (current-price uint))
  (match (map-get? positions { position-id: position-id })
    position
    (let (
      (new-ratio (calculate-collateral-ratio 
                   (get collateral-amount position)
                   (get synthetic-amount position)
                   current-price))
      (new-liq-price (calculate-liquidation-price
                       (get collateral-amount position)
                       (get synthetic-amount position)))
    )
      (map-set positions
        { position-id: position-id }
        (merge position {
          collateral-ratio: new-ratio,
          liquidation-price: new-liq-price,
          last-updated: stacks-block-height
        })
      )
      (ok new-ratio)
    )
    ERR_POSITION_NOT_FOUND
  )
)

;; Add position to user's position list
(define-private (add-position-to-user (user principal) (position-id uint))
  (let (
    (current-positions (default-to (list) (get position-ids (map-get? user-positions { user: user }))))
    (updated-positions (unwrap! (as-max-len? (append current-positions position-id) u100) ERR_INVALID_POSITION))
  )
    (map-set user-positions { user: user } { position-ids: updated-positions })
    (ok true)
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - ADMIN
;; =============================================================================

;; Initialize a new credit asset
(define-public (add-credit-asset 
  (name (string-ascii 64))
  (symbol (string-ascii 16))
  (initial-price uint)
  (credit-rating uint)
  (default-probability uint)
  (maturity uint)
  (total-supply uint)
)
  (let (
    (asset-id (var-get next-asset-id))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (and (> credit-rating u0) (<= credit-rating u10)) ERR_INVALID_AMOUNT)
    (asserts! (> initial-price u0) ERR_INVALID_AMOUNT)
    
    (map-set credit-assets
      { asset-id: asset-id }
      {
        name: name,
        symbol: symbol,
        price: initial-price,
        credit-rating: credit-rating,
        default-probability: default-probability,
        maturity: maturity,
        total-supply: total-supply,
        active: true
      }
    )
    
    (var-set next-asset-id (+ asset-id u1))
    (ok asset-id)
  )
)

;; Update asset price (oracle function)
(define-public (update-asset-price (asset-id uint) (new-price uint))
  (match (map-get? credit-assets { asset-id: asset-id })
    asset
    (begin
      (asserts! (or (is-eq tx-sender CONTRACT_OWNER) 
                   (is-eq (some tx-sender) (var-get oracle-address))) ERR_UNAUTHORIZED)
      (asserts! (> new-price u0) ERR_INVALID_AMOUNT)
      (asserts! (get active asset) ERR_CREDIT_ASSET_NOT_FOUND)
      
      (map-set credit-assets
        { asset-id: asset-id }
        (merge asset { price: new-price })
      )
      (ok new-price)
    )
    ERR_CREDIT_ASSET_NOT_FOUND
  )
)

;; Set oracle address
(define-public (set-oracle-address (new-oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set oracle-address (some new-oracle))
    (ok true)
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - CORE FUNCTIONALITY
;; =============================================================================

;; Open a new synthetic credit position
(define-public (open-position (asset-id uint) (synthetic-amount uint) (collateral-amount uint))
  (let (
    (position-id (var-get next-position-id))
    (asset (unwrap! (map-get? credit-assets { asset-id: asset-id }) ERR_CREDIT_ASSET_NOT_FOUND))
    (asset-price (get price asset))
    (collateral-ratio (calculate-collateral-ratio collateral-amount synthetic-amount asset-price))
    (liquidation-price (calculate-liquidation-price collateral-amount synthetic-amount))
  )
    ;; Validation checks
    (asserts! (not (var-get emergency-shutdown)) ERR_UNAUTHORIZED)
    (asserts! (get active asset) ERR_CREDIT_ASSET_NOT_FOUND)
    (asserts! (> synthetic-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (> collateral-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (validate-collateral-ratio collateral-ratio) ERR_INSUFFICIENT_COLLATERAL)
    (asserts! (< (var-get total-positions) MAX_POSITIONS) ERR_INVALID_POSITION)
    
    ;; Transfer collateral from user
    (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
    
    ;; Create position
    (map-set positions
      { position-id: position-id }
      {
        owner: tx-sender,
        asset-id: asset-id,
        synthetic-amount: synthetic-amount,
        collateral-amount: collateral-amount,
        collateral-ratio: collateral-ratio,
        entry-price: asset-price,
        liquidation-price: liquidation-price,
        created-at: stacks-block-height,
        last-updated: stacks-block-height,
        active: true
      }
    )
    
    ;; Update user positions
    (try! (add-position-to-user tx-sender position-id))
    
    ;; Update global state
    (var-set next-position-id (+ position-id u1))
    (var-set total-positions (+ (var-get total-positions) u1))
    (var-set total-collateral (+ (var-get total-collateral) collateral-amount))
    
    (ok position-id)
  )
)

;; Add collateral to existing position
(define-public (add-collateral (position-id uint) (additional-collateral uint))
  (match (map-get? positions { position-id: position-id })
    position
    (let (
      (asset (unwrap! (map-get? credit-assets { asset-id: (get asset-id position) }) ERR_CREDIT_ASSET_NOT_FOUND))
      (new-collateral (+ (get collateral-amount position) additional-collateral))
      (new-ratio (calculate-collateral-ratio new-collateral (get synthetic-amount position) (get price asset)))
      (new-liq-price (calculate-liquidation-price new-collateral (get synthetic-amount position)))
    )
      (asserts! (is-eq tx-sender (get owner position)) ERR_UNAUTHORIZED)
      (asserts! (get active position) ERR_INVALID_POSITION)
      (asserts! (> additional-collateral u0) ERR_INVALID_AMOUNT)
      
      ;; Transfer additional collateral
      (try! (stx-transfer? additional-collateral tx-sender (as-contract tx-sender)))
      
      ;; Update position
      (map-set positions
        { position-id: position-id }
        (merge position {
          collateral-amount: new-collateral,
          collateral-ratio: new-ratio,
          liquidation-price: new-liq-price,
          last-updated: stacks-block-height
        })
      )
      
      (var-set total-collateral (+ (var-get total-collateral) additional-collateral))
      (ok new-ratio)
    )
    ERR_POSITION_NOT_FOUND
  )
)

;; Close position and withdraw collateral
(define-public (close-position (position-id uint))
  (match (map-get? positions { position-id: position-id })
    position
    (begin
      (asserts! (is-eq tx-sender (get owner position)) ERR_UNAUTHORIZED)
      (asserts! (get active position) ERR_INVALID_POSITION)
      
      ;; Return collateral to owner
      (try! (as-contract (stx-transfer? (get collateral-amount position) tx-sender (get owner position))))
      
      ;; Mark position as inactive
      (map-set positions
        { position-id: position-id }
        (merge position { active: false, last-updated: stacks-block-height })
      )
      
      ;; Update global state
      (var-set total-positions (- (var-get total-positions) u1))
      (var-set total-collateral (- (var-get total-collateral) (get collateral-amount position)))
      
      (ok (get collateral-amount position))
    )
    ERR_POSITION_NOT_FOUND
  )
)

;; Liquidate undercollateralized position
(define-public (liquidate-position (position-id uint))
  (match (map-get? positions { position-id: position-id })
    position
    (let (
      (asset (unwrap! (map-get? credit-assets { asset-id: (get asset-id position) }) ERR_CREDIT_ASSET_NOT_FOUND))
      (current-ratio (calculate-collateral-ratio 
                       (get collateral-amount position)
                       (get synthetic-amount position)
                       (get price asset)))
      (liquidation-bonus (/ (* (get collateral-amount position) LIQUIDATION_PENALTY) PRECISION))
      (remaining-collateral (- (get collateral-amount position) liquidation-bonus))
    )
      (asserts! (get active position) ERR_INVALID_POSITION)
      (asserts! (< current-ratio LIQUIDATION_THRESHOLD) ERR_LIQUIDATION_NOT_ALLOWED)
      
      ;; Transfer liquidation bonus to liquidator
      (try! (as-contract (stx-transfer? liquidation-bonus tx-sender tx-sender)))
      
      ;; Return remaining collateral to position owner
      (try! (as-contract (stx-transfer? remaining-collateral tx-sender (get owner position))))
      
      ;; Mark position as liquidated
      (map-set positions
        { position-id: position-id }
        (merge position { active: false, last-updated: stacks-block-height })
      )
      
      ;; Add to liquidation queue for record keeping
      (map-set liquidation-queue
        { position-id: position-id }
        {
          liquidation-price: (get price asset),
          liquidation-block: stacks-block-height,
          liquidator: (some tx-sender)
        }
      )
      
      ;; Update global state
      (var-set total-positions (- (var-get total-positions) u1))
      (var-set total-collateral (- (var-get total-collateral) (get collateral-amount position)))
      (var-set protocol-fees (+ (var-get protocol-fees) liquidation-bonus))
      
      (ok liquidation-bonus)
    )
    ERR_POSITION_NOT_FOUND
  )
)

;; =============================================================================
;; READ-ONLY FUNCTIONS
;; =============================================================================

;; Get credit asset information
(define-read-only (get-credit-asset (asset-id uint))
  (map-get? credit-assets { asset-id: asset-id })
)

;; Get position information
(define-read-only (get-position (position-id uint))
  (map-get? positions { position-id: position-id })
)

;; Get user's positions
(define-read-only (get-user-positions (user principal))
  (map-get? user-positions { user: user })
)

;; Get collateral balance
(define-read-only (get-collateral-balance (user principal))
  (map-get? collateral-balances { user: user })
)

;; Get position health ratio
(define-read-only (get-position-health (position-id uint))
  (match (map-get? positions { position-id: position-id })
    position
    (match (map-get? credit-assets { asset-id: (get asset-id position) })
      asset
      (let (
        (current-ratio (calculate-collateral-ratio
                         (get collateral-amount position)
                         (get synthetic-amount position)
                         (get price asset)))
      )
        (ok {
          position-id: position-id,
          collateral-ratio: current-ratio,
          liquidation-threshold: LIQUIDATION_THRESHOLD,
          health-factor: (/ current-ratio LIQUIDATION_THRESHOLD),
          is-healthy: (>= current-ratio LIQUIDATION_THRESHOLD)
        })
      )
      ERR_CREDIT_ASSET_NOT_FOUND
    )
    ERR_POSITION_NOT_FOUND
  )
)

;; Get protocol statistics
(define-read-only (get-protocol-stats)
  (ok {
    total-positions: (var-get total-positions),
    total-collateral: (var-get total-collateral),
    protocol-fees: (var-get protocol-fees),
    next-asset-id: (var-get next-asset-id),
    next-position-id: (var-get next-position-id),
    emergency-shutdown: (var-get emergency-shutdown)
  })
)

;; Check if position can be liquidated
(define-read-only (can-liquidate (position-id uint))
  (match (map-get? positions { position-id: position-id })
    position
    (match (map-get? credit-assets { asset-id: (get asset-id position) })
      asset
      (let (
        (current-ratio (calculate-collateral-ratio
                         (get collateral-amount position)
                         (get synthetic-amount position)
                         (get price asset)))
      )
        (ok (and (get active position) (< current-ratio LIQUIDATION_THRESHOLD)))
      )
      ERR_CREDIT_ASSET_NOT_FOUND
    )
    ERR_POSITION_NOT_FOUND
  )
)
