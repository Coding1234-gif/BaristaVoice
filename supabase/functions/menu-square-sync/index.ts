// Supabase Edge Function: menu-square-sync
//
// BaristaVoice menu_items -> Square Catalog.
//
// Reads the active MenuItem JSON from Supabase and creates/updates:
//   - Square categories
//   - Square items
//   - Square item variations (sizes)
//   - Square modifier lists
//   - Square modifiers
//
// This is deliberately separate from pos-square-sync.
//
// pos-square-sync:
//     Square -> pos_products
//
// menu-square-sync:
//     menu_items -> Square
//
// IMPORTANT:
// This function matches existing Square catalog objects primarily by name.
// If a menu item is renamed in Supabase, the first sync after the rename can
// create a new Square item rather than recognizing the old one.
//
// The Square access token is resolved server-side from Vault and is never
// returned to the caller or written to logs.

import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SQUARE_ENVIRONMENT =
  (Deno.env.get("SQUARE_ENVIRONMENT") ?? "sandbox") as
    | "sandbox"
    | "production";

const SQUARE_VERSION =
  Deno.env.get("SQUARE_VERSION") ?? "2026-08-19";

const SQUARE_CURRENCY =
  Deno.env.get("SQUARE_CURRENCY") ?? "GBP";

const SQUARE_BASE_URL =
  SQUARE_ENVIRONMENT === "production"
    ? "https://connect.squareup.com"
    : "https://connect.squareupsandbox.com";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface MenuSize {
  name?: string;
  priceDelta?: number;
}

interface MenuOption {
  name?: string;
  priceDelta?: number;
}

interface MenuItemData {
  id?: string;
  name?: string;
  description?: string;
  category?: string | null;
  basePrice?: number;
  sizes?: MenuSize[];
  modifiers?: MenuOption[];
  milkOptions?: MenuOption[];
  temperatureOptions?: string[];
  decafAvailable?: boolean;
  available?: boolean;
  popular?: boolean;
  imageUrl?: string | null;
  allergens?: string[];
  dietaryTags?: string[];
}

interface MenuItemRow {
  id: string;
  cafe_id: string;
  data: MenuItemData;
}

interface SquareCatalogObject {
  id: string;
  type: string;
  // Square's optimistic-concurrency field, present on every catalog object
  // (including nested ITEM_VARIATION/MODIFIER children, each versioned
  // independently of their parent). Required on batch-upsert for any object
  // using a real Square id (an update); must be omitted for an object using
  // a client-supplied `#temp` id (a create) — Square assigns the first
  // version itself. Omitting it on an update is what produces
  // VERSION_MISMATCH: Square treats a missing version on a real id as
  // stale rather than as "skip the check."
  version?: number;
  is_deleted?: boolean;
  item_data?: {
    name?: string;
    description?: string;
    description_html?: string;
    categories?: Array<{
      id: string;
      ordinal?: number;
    }>;
    variations?: SquareCatalogObject[];
    modifier_list_info?: Array<{
      modifier_list_id: string;
      min_selected_modifiers?: number;
      max_selected_modifiers?: number;
      enabled?: boolean;
    }>;
    product_type?: string;
  };
  item_variation_data?: {
    item_id?: string;
    name?: string;
    price_money?: {
      amount?: number;
      currency?: string;
    };
  };
  category_data?: {
    name?: string;
  };
  modifier_list_data?: {
    name?: string;
    modifiers?: SquareCatalogObject[];
    min_selected_modifiers?: number;
    max_selected_modifiers?: number;
    allow_quantities?: boolean;
    modifier_type?: string;
  };
  modifier_data?: {
    modifier_list_id?: string;
    name?: string;
    price_money?: {
      amount?: number;
      currency?: string;
    };
  };
}

interface SquareCatalogListResponse {
  objects?: SquareCatalogObject[];
  cursor?: string;
}

interface SquareBatchResponse {
  errors?: Array<{
    category?: string;
    code?: string;
    detail?: string;
    field?: string;
  }>;
  objects?: SquareCatalogObject[];
  id_mappings?: Array<{
    client_object_id: string;
    object_id: string;
  }>;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function slug(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 70);
}

function moneyToMinorUnits(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.round(value * 100);
}

function normalizeName(value: string | undefined | null): string {
  return (value ?? "").trim().toLowerCase();
}

function uniqueNames(values: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];

  for (const value of values) {
    const clean = value.trim();
    if (!clean) continue;

    const key = normalizeName(clean);
    if (seen.has(key)) continue;

    seen.add(key);
    result.push(clean);
  }

  return result;
}

function htmlEscape(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

// ---------------------------------------------------------------------------
// Square catalog fetching
// ---------------------------------------------------------------------------

async function fetchAllSquareCatalogObjects(
  accessToken: string,
): Promise<SquareCatalogObject[]> {
  const all: SquareCatalogObject[] = [];
  let cursor: string | undefined;

  do {
    const url = new URL(`${SQUARE_BASE_URL}/v2/catalog/list`);

    // We need these types for matching existing objects.
    url.searchParams.set(
      "types",
      "ITEM,CATEGORY,MODIFIER_LIST",
    );

    if (cursor) {
      url.searchParams.set("cursor", cursor);
    }

    const response = await fetch(url.toString(), {
      method: "GET",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Square-Version": SQUARE_VERSION,
        "Content-Type": "application/json",
      },
    });

    if (!response.ok) {
      const detail = await response.text().catch(() => "");

      throw new Error(
        `Square catalog fetch failed (${response.status}): ${detail.slice(
          0,
          500,
        )}`,
      );
    }

    const body =
      (await response.json()) as SquareCatalogListResponse;

    all.push(...(body.objects ?? []));
    cursor = body.cursor || undefined;
  } while (cursor);

  return all;
}

// ---------------------------------------------------------------------------
// Existing-object lookup
// ---------------------------------------------------------------------------

function findCategory(
  objects: SquareCatalogObject[],
  categoryName: string,
): SquareCatalogObject | undefined {
  const target = normalizeName(categoryName);

  return objects.find(
    (object) =>
      object.type === "CATEGORY" &&
      !object.is_deleted &&
      normalizeName(object.category_data?.name) === target,
  );
}

function findItem(
  objects: SquareCatalogObject[],
  itemName: string,
): SquareCatalogObject | undefined {
  const target = normalizeName(itemName);

  return objects.find(
    (object) =>
      object.type === "ITEM" &&
      !object.is_deleted &&
      normalizeName(object.item_data?.name) === target,
  );
}

function findModifierList(
  objects: SquareCatalogObject[],
  modifierListName: string,
): SquareCatalogObject | undefined {
  const target = normalizeName(modifierListName);

  return objects.find(
    (object) =>
      object.type === "MODIFIER_LIST" &&
      !object.is_deleted &&
      normalizeName(object.modifier_list_data?.name) === target,
  );
}

// ---------------------------------------------------------------------------
// Modifier-list construction
// ---------------------------------------------------------------------------

interface ModifierListDefinition {
  name: string;
  options: Array<{
    name: string;
    priceDelta: number;
  }>;
  minSelected: number;
  maxSelected: number;
}

function buildModifierListDefinitions(
  menuItem: MenuItemData,
): ModifierListDefinition[] {
  const definitions: ModifierListDefinition[] = [];

  // Milk
  if ((menuItem.milkOptions ?? []).length > 0) {
    definitions.push({
      name: `BV - ${menuItem.name ?? "Item"} - Milk`,
      options: (menuItem.milkOptions ?? [])
        .filter((option) => option.name?.trim())
        .map((option) => ({
          name: option.name!.trim(),
          priceDelta: Number(option.priceDelta ?? 0),
        })),
      minSelected: 0,
      maxSelected: 1,
    });
  }

  // Add-ons / modifiers
  if ((menuItem.modifiers ?? []).length > 0) {
    definitions.push({
      name: `BV - ${menuItem.name ?? "Item"} - Add-ons`,
      options: (menuItem.modifiers ?? [])
        .filter((option) => option.name?.trim())
        .map((option) => ({
          name: option.name!.trim(),
          priceDelta: Number(option.priceDelta ?? 0),
        })),
      minSelected: 0,
      maxSelected: 0,
    });
  }

  // Temperature
  const temperatures = uniqueNames(
    (menuItem.temperatureOptions ?? []).map((value) =>
      String(value),
    ),
  );

  if (temperatures.length > 0) {
    definitions.push({
      name: `BV - ${menuItem.name ?? "Item"} - Temperature`,
      options: temperatures.map((temperature) => ({
        name: temperature,
        priceDelta: 0,
      })),
      minSelected: 0,
      maxSelected: 1,
    });
  }

  // Decaf
  if (menuItem.decafAvailable === true) {
    definitions.push({
      name: `BV - ${menuItem.name ?? "Item"} - Decaf`,
      options: [
        {
          name: "Decaf",
          priceDelta: 0,
        },
      ],
      minSelected: 0,
      maxSelected: 1,
    });
  }

  return definitions.filter(
    (definition) => definition.options.length > 0,
  );
}

// ---------------------------------------------------------------------------
// Build Square modifier list
// ---------------------------------------------------------------------------

function buildModifierListObject(
  definition: ModifierListDefinition,
  existing: SquareCatalogObject | undefined,
  temporaryPrefix: string,
): {
  object: SquareCatalogObject;
  temporaryId: string | null;
} {
  const isExisting = !!existing;

  const listId = isExisting
    ? existing!.id
    : `#${temporaryPrefix}_list`;

  const existingModifiers = new Map<string, SquareCatalogObject>();

  for (const modifier of existing?.modifier_list_data?.modifiers ?? []) {
    const modifierName = normalizeName(
      modifier.modifier_data?.name,
    );

    if (modifierName) {
      existingModifiers.set(modifierName, modifier);
    }
  }

  const modifiers: SquareCatalogObject[] =
    definition.options.map((option, index) => {
      const existingModifier = existingModifiers.get(
        normalizeName(option.name),
      );

      const modifierId =
        existingModifier?.id ??
        `#${temporaryPrefix}_modifier_${index}`;

      return {
        id: modifierId,
        type: "MODIFIER",
        // Undefined (dropped by JSON.stringify) for a brand-new `#temp`
        // modifier; the real current version for one matched by name to an
        // existing Square MODIFIER — never a guessed/default value.
        version: existingModifier?.version,
        modifier_data: {
          modifier_list_id: listId,
          name: option.name,
          price_money: {
            amount: moneyToMinorUnits(option.priceDelta),
            currency: SQUARE_CURRENCY,
          },
        },
      };
    });

  const object: SquareCatalogObject = {
    id: listId,
    type: "MODIFIER_LIST",
    // Same rule as the modifier above, one level up: only set when this
    // list matched an existing Square MODIFIER_LIST by name.
    version: existing?.version,
    modifier_list_data: {
      name: definition.name,
      modifier_type: "LIST",
      min_selected_modifiers: definition.minSelected,
      max_selected_modifiers: definition.maxSelected,
      allow_quantities: false,
      modifiers,
    },
  };

  return {
    object,
    temporaryId: isExisting ? null : listId,
  };
}

// ---------------------------------------------------------------------------
// Build Square item
// ---------------------------------------------------------------------------

function buildItemObject(
  menuItem: MenuItemData,
  existing: SquareCatalogObject | undefined,
  categoryId: string | undefined,
  modifierListIds: string[],
  temporaryPrefix: string,
): SquareCatalogObject {
  const itemId =
    existing?.id ?? `#${temporaryPrefix}_item`;

  const existingVariations = new Map<string, SquareCatalogObject>();

  for (const variation of existing?.item_data?.variations ?? []) {
    const variationName = normalizeName(
      variation.item_variation_data?.name,
    );

    if (variationName) {
      existingVariations.set(
        variationName,
        variation,
      );
    }
  }

  const sizes = menuItem.sizes ?? [];

  let variationDefinitions: Array<{
    name: string;
    price: number;
  }>;

  if (sizes.length > 0) {
    variationDefinitions = sizes
      .filter((size) => size.name?.trim())
      .map((size) => ({
        name: size.name!.trim(),
        price:
          Number(menuItem.basePrice ?? 0) +
          Number(size.priceDelta ?? 0),
      }));
  } else {
    variationDefinitions = [
      {
        name: "Regular",
        price: Number(menuItem.basePrice ?? 0),
      },
    ];
  }

  const variations = variationDefinitions.map(
    (variation, index) => {
      const existingVariation =
        existingVariations.get(
          normalizeName(variation.name),
        );

      return {
        id:
          existingVariation?.id ??
          `#${temporaryPrefix}_variation_${index}`,
        type: "ITEM_VARIATION",
        // Undefined (dropped by JSON.stringify) for a brand-new `#temp`
        // variation (e.g. a size just added in Supabase); the real current
        // version for one matched by name to an existing Square
        // ITEM_VARIATION — independent of the parent item's own version.
        version: existingVariation?.version,
        item_variation_data: {
          item_id: itemId,
          name: variation.name,
          pricing_type: "FIXED_PRICING",
          price_money: {
            amount: moneyToMinorUnits(
              variation.price,
            ),
            currency: SQUARE_CURRENCY,
          },
        },
      };
    },
  );

  const itemData: Record<string, unknown> = {
    name: menuItem.name?.trim() || "Untitled item",
    product_type: "REGULAR",
    variations,
  };

  if (menuItem.description?.trim()) {
    itemData.description_html =
      `<p>${htmlEscape(menuItem.description.trim())}</p>`;
  }

  if (categoryId) {
    itemData.categories = [
      {
        id: categoryId,
      },
    ];
  }

  if (modifierListIds.length > 0) {
    itemData.modifier_list_info =
      modifierListIds.map((id, index) => ({
        modifier_list_id: id,
        min_selected_modifiers: -1,
        max_selected_modifiers: -1,
        enabled: true,
      }));
  } else {
    // Explicitly clear modifier lists on an existing item.
    itemData.modifier_list_info = [];
  }

  return {
    id: itemId,
    type: "ITEM",
    // Same rule as the variation above, one level up: only set when this
    // item matched an existing Square ITEM by name.
    version: existing?.version,
    present_at_all_locations: true,
    item_data: itemData,
  } as SquareCatalogObject;
}

// ---------------------------------------------------------------------------
// Batch upsert
// ---------------------------------------------------------------------------

async function batchUpsert(
  accessToken: string,
  objects: SquareCatalogObject[],
): Promise<SquareBatchResponse> {
  if (objects.length === 0) {
    return {
      objects: [],
      id_mappings: [],
    };
  }

  // Square currently permits up to 1,000 objects per batch and 10,000 total
  // objects per request. We use 900 to leave a little headroom.
  const batches: Array<{
    objects: SquareCatalogObject[];
  }> = [];

  for (let i = 0; i < objects.length; i += 900) {
    batches.push({
      objects: objects.slice(i, i + 900),
    });
  }

  const response = await fetch(
    `${SQUARE_BASE_URL}/v2/catalog/batch-upsert`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Square-Version": SQUARE_VERSION,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        idempotency_key: crypto.randomUUID(),
        batches,
      }),
    },
  );

  const body =
    (await response.json().catch(() => ({}))) as SquareBatchResponse;

  if (!response.ok) {
    console.error("SQUARE BATCH UPSERT FAILED:", {
      status: response.status,
      errors: body.errors,
    });

    throw new Error(
      `Square catalog batch-upsert failed (${response.status}).`,
    );
  }

  if (body.errors && body.errors.length > 0) {
    console.error("SQUARE BATCH UPSERT ERRORS:", body.errors);

    throw new Error(
      `Square catalog batch-upsert returned ${body.errors.length} error(s).`,
    );
  }

  return body;
}

// ---------------------------------------------------------------------------
// Authorization
// ---------------------------------------------------------------------------

function authorizeConnectionAccess(
  profile: {
    role: string;
    cafeId: string | null;
  },
  connectionCafeId: string,
): { allowed: boolean; reason?: string } {
  if (profile.role === "super_admin") {
    return { allowed: true };
  }

  if (profile.role === "cafe_admin") {
    if (profile.cafeId === connectionCafeId) {
      return { allowed: true };
    }

    return {
      allowed: false,
      reason:
        "You do not have access to this POS connection.",
    };
  }

  return {
    allowed: false,
    reason:
      "Only cafe admins can trigger Square menu sync.",
  };
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

interface RequestBody {
  connectionId: string;
}

export async function handler(
  req: Request,
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders,
    });
  }

  if (req.method !== "POST") {
    return jsonResponse(
      {
        error: "Method not allowed.",
      },
      405,
    );
  }

  const authHeader =
    req.headers.get("Authorization");

  if (!authHeader) {
    return jsonResponse(
      {
        error: "Missing Authorization header.",
      },
      401,
    );
  }

  try {
    const body =
      (await req.json()) as RequestBody;

    if (!body.connectionId) {
      return jsonResponse(
        {
          error: "connectionId is required.",
        },
        400,
      );
    }

    // -----------------------------------------------------------------------
    // Verify caller
    // -----------------------------------------------------------------------

    const callerClient = createClient(
      SUPABASE_URL,
      SUPABASE_ANON_KEY,
      {
        global: {
          headers: {
            Authorization: authHeader,
          },
        },
      },
    );

    const {
      data: userData,
      error: userError,
    } = await callerClient.auth.getUser();

    if (userError || !userData.user) {
      return jsonResponse(
        {
          error:
            "Invalid or expired session.",
        },
        401,
      );
    }

    // -----------------------------------------------------------------------
    // Service-role client
    // -----------------------------------------------------------------------

    const adminClient = createClient(
      SUPABASE_URL,
      SUPABASE_SERVICE_ROLE_KEY,
    );

    // -----------------------------------------------------------------------
    // Profile / authorization
    // -----------------------------------------------------------------------

    const {
      data: profile,
      error: profileError,
    } = await adminClient
      .from("profiles")
      .select("role, cafe_id")
      .eq("id", userData.user.id)
      .maybeSingle();

    if (
      profileError ||
      !profile ||
      !(
        profile.role === "cafe_admin" ||
        profile.role === "super_admin"
      )
    ) {
      return jsonResponse(
        {
          error:
            "Only cafe admins can trigger Square menu sync.",
        },
        403,
      );
    }

    // -----------------------------------------------------------------------
    // POS connection
    // -----------------------------------------------------------------------

    const {
      data: connection,
      error: connectionError,
    } = await adminClient
      .from("pos_connections")
      .select(
        "id, cafe_id, provider, status, access_token_secret_id, token_expires_at",
      )
      .eq("id", body.connectionId)
      .maybeSingle();

    if (
      connectionError ||
      !connection
    ) {
      return jsonResponse(
        {
          error:
            "POS connection not found.",
        },
        404,
      );
    }

    const authz =
      authorizeConnectionAccess(
        {
          role: profile.role as string,
          cafeId:
            profile.cafe_id as string | null,
        },
        connection.cafe_id as string,
      );

    if (!authz.allowed) {
      return jsonResponse(
        {
          error: authz.reason,
        },
        403,
      );
    }

    if (connection.provider !== "square") {
      return jsonResponse(
        {
          error:
            `This function only supports Square connections (got "${connection.provider}").`,
        },
        400,
      );
    }

    if (
      connection.status ===
      "disconnected"
    ) {
      return jsonResponse(
        {
          error:
            "This Square connection is disconnected — reconnect it before syncing.",
        },
        400,
      );
    }

    if (
      !connection.access_token_secret_id
    ) {
      return jsonResponse(
        {
          error:
            "This connection has no stored access token.",
        },
        400,
      );
    }

    if (
      connection.token_expires_at &&
      new Date(
        connection.token_expires_at as string,
      ) <= new Date()
    ) {
      await adminClient
        .from("pos_connections")
        .update({
          status: "error",
          last_error:
            "Square access token expired — reconnect required.",
        })
        .eq(
          "id",
          body.connectionId,
        );

      return jsonResponse(
        {
          error:
            "Square access token expired — reconnect required.",
        },
        401,
      );
    }

    // -----------------------------------------------------------------------
    // Vault access token
    // -----------------------------------------------------------------------

    const {
      data: accessToken,
      error: secretError,
    } = await adminClient.rpc(
      "get_vault_secret",
      {
        secret_id:
          connection.access_token_secret_id,
      },
    );

    if (
      secretError ||
      !accessToken
    ) {
      console.error(
        "Square Vault resolution failed:",
        {
          message:
            secretError?.message,
          code:
            secretError?.code,
        },
      );

      throw new Error(
        "Could not resolve the stored Square access token.",
      );
    }

    // -----------------------------------------------------------------------
    // Load active menu
    // -----------------------------------------------------------------------

    const {
      data: menuItems,
      error: menuError,
    } = await adminClient
      .from("menu_items")
      .select("id, cafe_id, data")
      .eq("cafe_id", connection.cafe_id);

    if (menuError) {
      throw new Error(
        `Could not load menu_items: ${menuError.message}`,
      );
    }

    if (
      !menuItems ||
      menuItems.length === 0
    ) {
      return jsonResponse(
        {
          connectionId:
            body.connectionId,
          message:
            "No active menu_items found for this café.",
          itemsSynced: 0,
          categoriesSynced: 0,
          modifierListsSynced: 0,
        },
      );
    }

    // -----------------------------------------------------------------------
    // Fetch existing Square catalog
    // -----------------------------------------------------------------------

    console.log(
      "SQUARE MENU SYNC START:",
      {
        environment:
          SQUARE_ENVIRONMENT,
        baseUrl:
          SQUARE_BASE_URL,
        menuItemCount:
          menuItems.length,
      },
    );

    const existingObjects =
      await fetchAllSquareCatalogObjects(
        accessToken,
      );

    console.log(
      "EXISTING SQUARE CATALOG:",
      {
        count:
          existingObjects.length,
        types: [
          ...new Set(
            existingObjects.map(
              (object) =>
                object.type,
            ),
          ),
        ],
      },
    );

    // -----------------------------------------------------------------------
    // Build category objects
    // -----------------------------------------------------------------------

    const categoryNames =
      uniqueNames(
        (menuItems as MenuItemRow[])
          .map(
            (row) =>
              row.data?.category ?? "",
          )
          .filter(Boolean),
      );

    const categoryIdByName =
      new Map<string, string>();

    const objectsToUpsert: SquareCatalogObject[] =
      [];

    for (
      const categoryName of categoryNames
    ) {
      const existing =
        findCategory(
          existingObjects,
          categoryName,
        );

      if (existing) {
        categoryIdByName.set(
          normalizeName(
            categoryName,
          ),
          existing.id,
        );
      } else {
        const temporaryId =
          `#category_${slug(categoryName)}`;

        categoryIdByName.set(
          normalizeName(
            categoryName,
          ),
          temporaryId,
        );

        objectsToUpsert.push({
          id: temporaryId,
          type: "CATEGORY",
          present_at_all_locations: true,
          category_data: {
            name: categoryName,
          },
        } as SquareCatalogObject);
      }
    }

    // -----------------------------------------------------------------------
    // Build items + modifiers
    // -----------------------------------------------------------------------

    let itemsToSync = 0;
    let modifierListsToSync = 0;

    for (
      const row of menuItems as MenuItemRow[]
    ) {
      const menuItem =
        row.data;

      if (
        !menuItem ||
        !menuItem.name?.trim()
      ) {
        console.warn(
          "Skipping menu item with no name:",
          row.id,
        );
        continue;
      }

      const itemName =
        menuItem.name.trim();

      const existingItem =
        findItem(
          existingObjects,
          itemName,
        );

      const modifierDefinitions =
        buildModifierListDefinitions(
          menuItem,
        );

      const modifierListIds: string[] =
        [];

      for (
        let index = 0;
        index <
        modifierDefinitions.length;
        index++
      ) {
        const definition =
          modifierDefinitions[
            index
          ];

        const existingList =
          findModifierList(
            existingObjects,
            definition.name,
          );

        const temporaryPrefix =
          `item_${slug(itemName)}_${index}`;

        const {
          object,
          temporaryId,
        } =
          buildModifierListObject(
            definition,
            existingList,
            temporaryPrefix,
          );

        objectsToUpsert.push(
          object,
        );

        modifierListsToSync++;

        modifierListIds.push(
          temporaryId ??
            existingList!.id,
        );
      }

      const categoryId =
        menuItem.category
          ? categoryIdByName.get(
              normalizeName(
                menuItem.category,
              ),
            )
          : undefined;

      const itemObject =
        buildItemObject(
          menuItem,
          existingItem,
          categoryId,
          modifierListIds,
          `menu_${slug(itemName)}`,
        );

      objectsToUpsert.push(
        itemObject,
      );

      itemsToSync++;
    }

    // -----------------------------------------------------------------------
    // Square batch upsert
    // -----------------------------------------------------------------------

    console.log(
      "SQUARE MENU UPSERT:",
      {
        objects:
          objectsToUpsert.length,
        items:
          itemsToSync,
        categories:
          categoryNames.length,
        modifierLists:
          modifierListsToSync,
      },
    );

    const result =
      await batchUpsert(
        accessToken,
        objectsToUpsert,
      );

    // -----------------------------------------------------------------------
    // Map created IDs back to useful diagnostics.
    // -----------------------------------------------------------------------

    console.log(
      "SQUARE MENU UPSERT COMPLETE:",
      {
        returnedObjects:
          result.objects?.length ?? 0,
        idMappings:
          result.id_mappings?.length ?? 0,
      },
    );

    // -----------------------------------------------------------------------
    // Update POS connection status
    // -----------------------------------------------------------------------

    const syncedAt =
      new Date().toISOString();

    await adminClient
      .from("pos_connections")
      .update({
        status: "active",
        last_synced_at:
          syncedAt,
        last_error: null,
      })
      .eq(
        "id",
        body.connectionId,
      );

    return jsonResponse({
      success: true,
      connectionId:
        body.connectionId,
      environment:
        SQUARE_ENVIRONMENT,
      currency:
        SQUARE_CURRENCY,
      menuItemsFound:
        menuItems.length,
      itemsSynced:
        itemsToSync,
      categoriesSynced:
        categoryNames.length,
      modifierListsSynced:
        modifierListsToSync,
      squareObjectsSubmitted:
        objectsToUpsert.length,
      squareObjectsReturned:
        result.objects?.length ?? 0,
      idMappings:
        result.id_mappings?.length ?? 0,
    });
  } catch (error) {
    console.error(
      "menu-square-sync failed:",
      error instanceof Error
        ? error.message
        : error,
    );

    return jsonResponse(
      {
        error:
          error instanceof Error
            ? error.message
            : "Square menu sync failed.",
      },
      500,
    );
  }
}

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------

if (import.meta.main) {
  Deno.serve(handler);
}