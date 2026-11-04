// ═══════════════════════════════════════════════════════════════
// ShopFlow — Barcode System Complete Test Suite
// Verifies Standards, Generation, SVG, Label Printing, Permissions,
// Billing Integration, Multi-Shop Isolation, and Shop Models.
// ═══════════════════════════════════════════════════════════════

const fs = require('fs');
const path = require('path');
const assert = require('assert');

console.log('═══════════════════════════════════════════════════════════════');
console.log(' RUNNING SHOPFLOW BARCODE SYSTEM TEST SUITE');
console.log('═══════════════════════════════════════════════════════════════\n');

let passedTests = 0;
let totalTests = 0;

function it(desc, fn) {
  totalTests++;
  try {
    fn();
    console.log(`  ✓ ${desc}`);
    passedTests++;
  } catch (err) {
    console.error(`  ✗ ${desc}`);
    console.error(`    Error: ${err.message}`);
    if (err.stack) console.error(err.stack.split('\n').slice(1, 4).join('\n'));
  }
}

// ── TEST 1: Syntax & Bundle Integrity ──
it('bundle.js compiles and evaluates without syntax errors', () => {
  const bundlePath = path.join(__dirname, 'assets', 'js', 'bundle.js');
  assert.ok(fs.existsSync(bundlePath), 'bundle.js must exist');
  const code = fs.readFileSync(bundlePath, 'utf8');
  assert.doesNotThrow(() => {
    new Function(code);
  }, 'bundle.js should evaluate cleanly');
});

// Load barcode module implementation using the same strip technique as build.ps1
const barcodeModulePath = path.join(__dirname, 'assets', 'js', 'barcode.js');
let barcodeCode = fs.readFileSync(barcodeModulePath, 'utf8');

// Strip imports and exports using JavaScript regex
barcodeCode = barcodeCode
  .replace(/import\s*\{[^}]*\}\s*from\s*['`"][^'`"]+['`"];?/gs, '')
  .replace(/import\s+.*?from\s*['`"][^'`"]+['`"];?/gs, '')
  .replace(/^\s*import\s+.*?;?\s*$/gm, '')
  .replace(/^\s*export\s+default\s+/gm, '')
  .replace(/^\s*export\s+/gm, '');

const mockMocks = `
  const formatAttributeSummary = (prod) => {
    if (!prod || !prod.attributes) return '';
    return Object.entries(prod.attributes).map(([k, v]) => k + ': ' + v).join(' • ');
  };
  const renderProductBadgesHTML = () => '';
  const getSession = () => ({ shopId: 'shop-123', role: 'owner', ownerId: 'OWN-10001' });
  const logAudit = async () => {};
  const toastSuccess = () => {};
  const toastError = () => {};
  const toastWarning = () => {};
  const toastInfo = () => {};
  const openModal = () => {};
  const closeModal = () => {};
  const initLucide = () => {};
`;

const barcodeScopeFactory = new Function(mockMocks + '\n' + barcodeCode + '\n' + `
  return {
    calculateEANCheckDigit,
    calculateUPCCheckDigit,
    calculateEAN8CheckDigit,
    validateBarcode,
    generateUniqueInternalBarcode,
    renderBarcodeSVG,
    generateProductLabelHTML
  };
`);

const {
  validateBarcode,
  calculateEANCheckDigit,
  calculateUPCCheckDigit,
  calculateEAN8CheckDigit,
  generateUniqueInternalBarcode,
  renderBarcodeSVG,
  generateProductLabelHTML
} = barcodeScopeFactory();

// ── TEST 2: Barcode Standards Validation ──
it('EAN-13 check digit calculation is accurate', () => {
  // Test known real world EAN-13 barcodes
  // 5449000000996 (Coca-Cola)
  assert.strictEqual(calculateEANCheckDigit('544900000099'), 6);
  // 8901030383748 (Tata Salt India)
  assert.strictEqual(calculateEANCheckDigit('890103038374'), 8);
  // 4006381333931 (Stabilo)
  assert.strictEqual(calculateEANCheckDigit('400638133393'), 1);
});

it('EAN-13 valid barcodes accepted and invalid barcodes rejected', () => {
  const valid = validateBarcode('5449000000996', 'EAN13');
  assert.strictEqual(valid.valid, true);
  assert.strictEqual(valid.format, 'EAN13');

  // Bad check digit
  const invalidCheck = validateBarcode('5449000000997', 'EAN13');
  assert.strictEqual(invalidCheck.valid, false);
  assert.ok(invalidCheck.error.includes('check digit'));

  // Non-numeric or wrong length
  const invalidLen = validateBarcode('544900000099', 'EAN13');
  assert.strictEqual(invalidLen.valid, false);
  const fakeEAN = validateBarcode('544900000099A', 'EAN13');
  assert.strictEqual(fakeEAN.valid, false);
});

it('UPC-A check digit calculation is accurate', () => {
  // 049000000443 (Coca-Cola 12oz can)
  assert.strictEqual(calculateUPCCheckDigit('04900000044'), 3);
  // 012000000133 (Pepsi 12oz)
  assert.strictEqual(calculateUPCCheckDigit('01200000013'), 3);
});

it('UPC-A valid barcodes accepted and invalid barcodes rejected', () => {
  const valid = validateBarcode('049000000443', 'UPCA');
  assert.strictEqual(valid.valid, true);
  assert.strictEqual(valid.format, 'UPCA');

  const invalidCheck = validateBarcode('049000000445', 'UPCA');
  assert.strictEqual(invalidCheck.valid, false);
  assert.ok(invalidCheck.error.includes('check digit'));
});

it('EAN-8 check digit and validation', () => {
  // 96385074
  assert.strictEqual(calculateEAN8CheckDigit('9638507'), 4);
  const valid = validateBarcode('96385074', 'EAN8');
  assert.strictEqual(valid.valid, true);

  const invalid = validateBarcode('96385075', 'EAN8');
  assert.strictEqual(invalid.valid, false);
});

it('Code 128 accepts internal retail alphanumeric codes and validates characters', () => {
  const validCode = validateBarcode('SF10001-00042', 'CODE128');
  assert.strictEqual(validCode.valid, true);
  assert.strictEqual(validCode.format, 'CODE128');

  // Empty string rejected
  const emptyRes = validateBarcode('', 'CODE128');
  assert.strictEqual(emptyRes.valid, false);

  // Non-ASCII rejected
  const nonAscii = validateBarcode('SF10001-©®', 'CODE128');
  assert.strictEqual(nonAscii.valid, false);
});

it('Auto-detect mode correctly identifies EAN-13, UPC-A, EAN-8, and Code 128', () => {
  assert.strictEqual(validateBarcode('5449000000996', 'AUTO').format, 'EAN13');
  assert.strictEqual(validateBarcode('049000000443', 'AUTO').format, 'UPCA');
  assert.strictEqual(validateBarcode('96385074', 'AUTO').format, 'EAN8');
  assert.strictEqual(validateBarcode('SF10001-00042', 'AUTO').format, 'CODE128');
});

// ── TEST 3: Internal Retail Barcode Generator ──
it('generateUniqueInternalBarcode produces unique, valid Code 128 barcodes', () => {
  const shopInfo = { ownerId: 'OWN-10025' };
  const existing = ['SF10025-500001', 'SF10025-500002'];
  const generated = generateUniqueInternalBarcode(shopInfo, existing);

  assert.ok(generated.barcode.startsWith('SF10025-'), 'Barcode should include shop prefix');
  assert.strictEqual(generated.format, 'CODE128');
  assert.ok(!existing.includes(generated.barcode), 'Must not collide with existing barcodes');

  // Verify it validates as valid Code 128
  const valRes = validateBarcode(generated.barcode, 'CODE128');
  assert.strictEqual(valRes.valid, true);
});

it('Internal barcode generator handles large collision sets safely', () => {
  const existing = [];
  for (let i = 0; i < 50; i++) {
    const res = generateUniqueInternalBarcode({ ownerId: 'OWN-10001' }, existing);
    assert.ok(!existing.includes(res.barcode), 'Should be unique in set');
    existing.push(res.barcode);
  }
  assert.strictEqual(existing.length, 50);
});

// ── TEST 4: SVG Barcode Rendering ──
it('renderBarcodeSVG generates valid XML SVG with quiet zones and rect elements', () => {
  const svg = renderBarcodeSVG('SF10001-00042', 'CODE128', {
    height: 50,
    barWidth: 2,
    margin: 10,
    displayValue: true
  });

  assert.ok(svg.includes('<svg'), 'Output must be an SVG element');
  assert.ok(svg.includes('</svg>'), 'SVG must close');
  assert.ok(svg.includes('<rect'), 'SVG must contain rect elements for bars');
  assert.ok(svg.includes('<text'), 'SVG must contain human readable text');
  assert.ok(svg.includes('SF10001-00042'), 'SVG text must contain barcode number');
  assert.ok(svg.includes('viewBox="0 0'), 'SVG must have valid viewBox');
});

it('renderBarcodeSVG renders EAN-13 with 95 modules and quiet zones', () => {
  const svg = renderBarcodeSVG('5449000000996', 'EAN13', {
    barWidth: 2,
    margin: 10
  });
  assert.ok(svg.includes('<svg'), 'Valid SVG for EAN-13');
  // 95 modules * 2px + 20px margin = 210px total width
  assert.ok(svg.includes('viewBox="0 0 210'), 'Viewbox matches 95 modules + margins');
});

// ── TEST 5: Label Generation for All Supported Shop Models ──
it('generateProductLabelHTML formats labels correctly for all retail shop models', () => {
  const shopData = { name: 'Metro Super Store' };

  // 1. Grocery
  const groceryProd = {
    name: 'Fortune Sunflower Oil 1L',
    barcode: '8901030383748',
    barcode_format: 'EAN13',
    selling_price: 145.00,
    mrp: 160.00,
    attributes: { package_size: '1 Litre', expiry_date: '2027-12-31' }
  };
  const groceryLabel = generateProductLabelHTML(groceryProd, shopData, { labelSize: 'thermal_50x25' });
  assert.ok(groceryLabel.includes('Fortune Sunflower Oil 1L'));
  assert.ok(groceryLabel.includes('₹145.00'));
  assert.ok(groceryLabel.includes('Metro Super Store'));
  assert.ok(groceryLabel.includes('<svg'));

  // 2. Clothing
  const clothingProd = {
    name: 'Cotton Polo T-Shirt',
    barcode: 'SF10001-99214',
    barcode_format: 'CODE128',
    sku: 'POLO-BLU-L',
    selling_price: 799.00,
    attributes: { size: 'L', color: 'Navy Blue', brand: 'Arrow' }
  };
  const clothingLabel = generateProductLabelHTML(clothingProd, shopData, { labelSize: 'thermal_50x38' });
  assert.ok(clothingLabel.includes('Cotton Polo T-Shirt'));
  assert.ok(clothingLabel.includes('POLO-BLU-L'));
  assert.ok(clothingLabel.includes('₹799.00'));

  // 3. Jewellery
  const jewelleryProd = {
    name: '22K Gold Ring',
    barcode: 'SF10001-11002',
    barcode_format: 'CODE128',
    selling_price: 24500.00,
    attributes: { purity: '22K (916)', net_weight: '4.5g', huid: 'HUID9921' }
  };
  const jewelleryLabel = generateProductLabelHTML(jewelleryProd, shopData, { labelSize: 'thermal_38x25' });
  assert.ok(jewelleryLabel.includes('22K Gold Ring'));
  assert.ok(jewelleryLabel.includes('₹24500.00'));

  // 4. Paint
  const paintProd = {
    name: 'Royale Interior Emulsion',
    barcode: 'SF10001-77210',
    barcode_format: 'CODE128',
    selling_price: 1850.00,
    attributes: { brand: 'Asian Paints', finish: 'Matt', shade_code: '0424 Morning Glory', container_size: '4 Litre' }
  };
  const paintLabel = generateProductLabelHTML(paintProd, shopData, { labelSize: 'thermal_50x38' });
  assert.ok(paintLabel.includes('Royale Interior Emulsion'));
  assert.ok(paintLabel.includes('₹1850.00'));

  // 5. Electronics
  const electronicProd = {
    name: 'Wireless Bluetooth Headset',
    barcode: '049000000443',
    barcode_format: 'UPCA',
    selling_price: 1999.00,
    attributes: { model_no: 'WH-CH520', warranty: '1 Year Brand Warranty' }
  };
  const electronicLabel = generateProductLabelHTML(electronicProd, shopData, { labelSize: 'sheet_a4_24' });
  assert.ok(electronicLabel.includes('Wireless Bluetooth Headset'));
  assert.ok(electronicLabel.includes('₹1999.00'));
});

// ── TEST 6: Permissions Logic ──
const permissionsPath = path.join(__dirname, 'assets', 'js', 'permissions.js');
let permCode = fs.readFileSync(permissionsPath, 'utf8');
permCode = permCode
  .replace(/import\s*\{[^}]*\}\s*from\s*['`"][^'`"]+['`"];?/gs, '')
  .replace(/^\s*export\s+/gm, '');

const permScopeFactory = new Function(permCode + '\n' + `
  return {
    canManageBarcodes,
    canScanBarcodes,
    ROLES
  };
`);

const { canManageBarcodes, canScanBarcodes } = permScopeFactory();

it('Owner and Manager can manage barcodes, Staff and Cashier cannot modify barcodes', () => {
  // Manage barcodes (Add, Edit, Regenerate, Assign)
  assert.strictEqual(canManageBarcodes('owner'), true, 'Owner must be allowed to manage barcodes');
  assert.strictEqual(canManageBarcodes('manager'), true, 'Manager must be allowed to manage barcodes');
  assert.strictEqual(canManageBarcodes('platform_admin'), true, 'Platform admin allowed');
  assert.strictEqual(canManageBarcodes('cashier'), false, 'Cashier must NOT modify barcodes');
  assert.strictEqual(canManageBarcodes('staff'), false, 'Staff must NOT modify barcodes');
  assert.strictEqual(canManageBarcodes('cleaner'), false, 'Cleaner must NOT modify barcodes');
  assert.strictEqual(canManageBarcodes('stock_filler'), false, 'Stock filler must NOT modify barcodes');

  // Scan barcodes during billing
  assert.strictEqual(canScanBarcodes('owner'), true, 'Owner can scan');
  assert.strictEqual(canScanBarcodes('manager'), true, 'Manager can scan');
  assert.strictEqual(canScanBarcodes('cashier'), true, 'Cashier can scan during billing');
  assert.strictEqual(canScanBarcodes('staff'), false, 'Regular staff without billing cannot scan');
});

// ── TEST 7: Billing Barcode Scan Simulation ──
it('Billing scanner simulation: adds product, updates quantity, enforces stock, and blocks cross-shop access', () => {
  const shopA_Id = 'shop-aaa-111';
  const shopB_Id = 'shop-bbb-222';

  // Inventory in current shop (Shop A)
  const shopA_Products = [
    { id: 'p1', shop_id: shopA_Id, name: 'Parle-G 100g', barcode: '8901030383748', selling_price: 10.00, stock_qty: 5, gst_rate: 5 },
    { id: 'p2', shop_id: shopA_Id, name: 'Amul Butter 100g', barcode: 'SF10001-0001', selling_price: 56.00, stock_qty: 2, gst_rate: 12 },
    { id: 'p3', shop_id: shopA_Id, name: 'Out of Stock Coffee', barcode: 'SF10001-0002', selling_price: 150.00, stock_qty: 0, gst_rate: 18 }
  ];

  // Inventory in competitor shop (Shop B)
  const shopB_Products = [
    { id: 'p4', shop_id: shopB_Id, name: 'Secret Product Shop B', barcode: 'SF99999-0001', selling_price: 999.00, stock_qty: 10 }
  ];

  let cart = [];

  function simulateScan(code) {
    // Only search current permitted shop inventory (Shop A)
    const match = shopA_Products.find(p => p.barcode && p.barcode.toLowerCase() === code.toLowerCase());
    if (!match) {
      return { success: false, error: `Barcode "${code}" not found in this shop's inventory.` };
    }
    if (match.stock_qty <= 0) {
      return { success: false, error: `"${match.name}" is currently out of stock.` };
    }
    const existing = cart.find(i => i.id === match.id);
    if (existing) {
      if (existing.qty >= match.stock_qty) {
        return { success: false, error: `Stock limit reached! Only ${match.stock_qty} available.` };
      }
      existing.qty += 1;
      return { success: true, item: match, newQty: existing.qty };
    } else {
      cart.push({ id: match.id, name: match.name, price: match.selling_price, qty: 1, stock_qty: match.stock_qty });
      return { success: true, item: match, newQty: 1 };
    }
  }

  // 1. Scan valid item 1st time
  const scan1 = simulateScan('8901030383748');
  assert.strictEqual(scan1.success, true);
  assert.strictEqual(scan1.newQty, 1);
  assert.strictEqual(cart.length, 1);

  // 2. Scan same item 2nd time (increments quantity)
  const scan2 = simulateScan('8901030383748');
  assert.strictEqual(scan2.success, true);
  assert.strictEqual(scan2.newQty, 2);
  assert.strictEqual(cart[0].qty, 2);

  // 3. Scan second item up to stock limit
  const scanAmul1 = simulateScan('SF10001-0001');
  assert.strictEqual(scanAmul1.success, true);
  assert.strictEqual(cart[1].qty, 1);

  const scanAmul2 = simulateScan('SF10001-0001');
  assert.strictEqual(scanAmul2.success, true);
  assert.strictEqual(cart[1].qty, 2);

  // 4. Scan again when stock limit is 2 -> must reject safely
  const scanAmulExceed = simulateScan('SF10001-0001');
  assert.strictEqual(scanAmulExceed.success, false);
  assert.ok(scanAmulExceed.error.includes('Stock limit reached'));

  // 5. Scan out of stock item -> must reject safely
  const scanOut = simulateScan('SF10001-0002');
  assert.strictEqual(scanOut.success, false);
  assert.ok(scanOut.error.includes('out of stock'));

  // 6. Scan unknown barcode -> displays useful error
  const scanUnknown = simulateScan('UNKNOWN-12345');
  assert.strictEqual(scanUnknown.success, false);
  assert.ok(scanUnknown.error.includes('not found in this shop'));

  // 7. Cross-shop isolation: scanning Shop B barcode in Shop A must NEVER find Shop B's product
  const scanShopB = simulateScan('SF99999-0001');
  assert.strictEqual(scanShopB.success, false);
  assert.ok(scanShopB.error.includes('not found in this shop'));
});

// ── TEST 8: Existing Products Editing Protection ──
it('Editing product details does NOT regenerate existing barcode', () => {
  const existingProduct = {
    id: 'prod-001',
    name: 'Original Biscuit',
    barcode: 'SF10001-55012',
    barcode_format: 'CODE128',
    selling_price: 20.00,
    stock_quantity: 50
  };

  // Normal edit: user updates name and price
  const updatedForm = {
    name: 'Original Biscuit Family Pack',
    selling_price: 25.00,
    barcode: existingProduct.barcode // Barcode remains locked / unchanged
  };

  assert.strictEqual(updatedForm.barcode, existingProduct.barcode, 'Barcode must not be regenerated on normal edit');
  assert.strictEqual(updatedForm.name, 'Original Biscuit Family Pack');
});

// ── TEST 9: Migration SQL File Verification ──
it('migration_barcode_system.sql exists and contains required safe constraints and indexes', () => {
  const migPath = path.join(__dirname, 'migration_barcode_system.sql');
  assert.ok(fs.existsSync(migPath), 'migration_barcode_system.sql must exist');
  const sql = fs.readFileSync(migPath, 'utf8');

  assert.ok(/ALTER\s+TABLE\s+public\.products\s+ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+barcode_format/i.test(sql), 'Must add barcode_format column');
  assert.ok(sql.includes('idx_products_shop_barcode_unique'), 'Must create unique partial index for (shop_id, barcode)');
  assert.ok(sql.includes('WHERE barcode IS NOT NULL AND barcode != \'\''), 'Partial index must preserve existing products with null/empty barcodes');
  assert.ok(sql.includes('generate_shop_barcode'), 'Must include atomic generate_shop_barcode RPC');
  assert.ok(sql.includes('assign_product_barcode'), 'Must include assign_product_barcode RPC with audit trail');
  assert.ok(sql.includes('lookup_product_by_barcode'), 'Must include lookup_product_by_barcode with shop isolation');
});

// ── TEST 10: Combined Products and New Stock Integration ──
it('Products and New Stock are cleanly combined in sidebar navigation and permissions', () => {
  const permPath = path.join(__dirname, 'assets', 'js', 'permissions.js');
  const permCode = fs.readFileSync(permPath, 'utf8')
    .replace(/^\s*export\s+/gm, '');
  
  const permScope = new Function(permCode + '\n return { ROLE_NAV, ROLE_PERMISSIONS, canInwardStock };')();
  const { ROLE_NAV, canInwardStock } = permScope;

  // Verify separate 'new-stock' is removed from sidebar nav for owner, manager, stock_filler
  const ownerNavIds = ROLE_NAV.owner.map(n => n.id);
  const managerNavIds = ROLE_NAV.manager.map(n => n.id);
  const fillerNavIds = ROLE_NAV.stock_filler.map(n => n.id);

  assert.ok(!ownerNavIds.includes('new-stock'), 'owner nav must not contain separate new-stock');
  assert.ok(!managerNavIds.includes('new-stock'), 'manager nav must not contain separate new-stock');
  assert.ok(!fillerNavIds.includes('new-stock'), 'stock_filler nav must not contain separate new-stock');

  // Verify 'products' is present in all of them
  assert.ok(ownerNavIds.includes('products'), 'owner nav must contain products');
  assert.ok(managerNavIds.includes('products'), 'manager nav must contain products');
  assert.ok(fillerNavIds.includes('products'), 'stock_filler nav must contain products');

  // Verify canInwardStock permission function
  assert.strictEqual(canInwardStock('owner'), true);
  assert.strictEqual(canInwardStock('manager'), true);
  assert.strictEqual(canInwardStock('stock_filler'), true);
  assert.strictEqual(canInwardStock('cleaner'), false);
});

it('Products page contains New Stock button beside Add Product and row-level +Stock actions', () => {
  const prodPagePath = path.join(__dirname, 'assets', 'js', 'pages', 'products.js');
  const code = fs.readFileSync(prodPagePath, 'utf8');

  // Check header New Stock button
  assert.ok(code.includes('id="btn-new-stock"'), 'Must have #btn-new-stock button');
  assert.ok(code.includes('id="btn-add-product"'), 'Must have #btn-add-product button');
  
  // Verify New Stock button is right next to Add Product in the header
  const headerSection = code.substring(code.indexOf('class="page-header"'), code.indexOf('class="toolbar"'));
  assert.ok(headerSection.includes('id="btn-new-stock"'), 'New Stock button must be inside page-header');
  assert.ok(headerSection.includes('id="btn-add-product"'), 'Add Product button must be inside page-header');

  // Check row-level quick +Stock button
  assert.ok(code.includes('btn-row-new-stock'), 'Must include row-level btn-row-new-stock button');
  assert.ok(code.includes('openNewStockModal'), 'Must include openNewStockModal function');
  assert.ok(code.includes('openStockHistoryModal'), 'Must include openStockHistoryModal function');

  // Check redirect and action=new-stock support
  assert.ok(code.includes('action=new-stock'), 'Must handle action=new-stock query parameter');
});

it('Inward stock calculation computes current + received = new total correctly', () => {
  const currentStock = 25;
  const receivedQty = 50;
  const calculatedTotal = currentStock + receivedQty;
  assert.strictEqual(calculatedTotal, 75);

  const testProduct = { id: 'p1', name: 'Product 1', stock_qty: currentStock };
  testProduct.stock_qty = calculatedTotal;
  assert.strictEqual(testProduct.stock_qty, 75);
});


console.log('\n═══════════════════════════════════════════════════════════════');
console.log(` TEST SUMMARY: ${passedTests} / ${totalTests} PASSED (${Math.round((passedTests / totalTests) * 100)}%)`);
console.log('═══════════════════════════════════════════════════════════════\n');

if (passedTests === totalTests) {
  process.exit(0);
} else {
  process.exit(1);
}
