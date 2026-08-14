/**
 * WEALTH MANAGEMENT POLICY LAYER
 * ==============================
 *
 * Single entry point. Import from here, not from individual modules, so
 * internal file reorganisation doesn't break consumers.
 *
 *   import { legacyPolicy, TAX_2026 } from "./src";
 */

// Core policy — goal claims, sleeves, alt function budgets, glide, rebalance
export * from "./policy-schema-v2";

// Household intake — human capital, Social Security, goals, required return
export * from "./household-module";

// Exposure & tilts — country x sector matrix, generalized tilts, ETF lineup
export * from "./exposure-matrix-module";

// Layer separation — strategic vs tactical, holding periods, attribution
export * from "./layer-separation-module";

// Tax parameters & terminal disposition — SALT, estate, step-up, IRD
export * from "./tax-disposition-module";

// Fixed income & liabilities — vehicles, location, balance sheet view
export * from "./fixed-income-liability-module";

// Planning surface — transition, risk tolerance, insurance, charitable, 529
export * from "./planning-surface-module";

/**
 * NOTE ON sector-tilt-module.ts
 *
 * Superseded by exposure-matrix-module for tilt mechanics, but still the
 * canonical source for the `Sector` type and SECTOR_ETF map, which the matrix
 * imports. Not re-exported here to avoid ambiguity with the matrix's
 * generalized Tilt type — import directly if you need it.
 */
