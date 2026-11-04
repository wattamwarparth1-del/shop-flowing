$baseDir = "C:\Users\parth\.gemini\antigravity\scratch\shopflow\assets\js"
$files = @(
    "auth.js",
    "permissions.js",
    "categories.js",
    "product-attributes.js",
    "router.js",
    "ui.js",
    "audit.js",
    "barcode.js",
    "udhar.js",
    "pages\login.js",
    "pages\register.js",
    "pages\verify-email.js",
    "pages\dashboard.js",
    "pages\billing.js",
    "pages\sales.js",
    "pages\stock.js",
    "pages\new-stock.js",
    "pages\products.js",
    "pages\customers.js",
    "pages\staff.js",
    "pages\machines.js",
    "pages\bill-customizer.js",
    "pages\reports.js",
    "pages\settings.js",
    "pages\account.js",
    "pages\staff-dashboard.js",
    "pages\product-performance.js",
    "pages\communication.js"
)

$bundle = "(function() {
  'use strict';

"

$idx = 1
foreach ($f in $files) {
    $path = Join-Path $baseDir $f
    $content = Get-Content $path -Raw -Encoding UTF8
    
    # Remove multi-line and single-line import lines
    $content = [regex]::Replace($content, "(?s)import\s*\{[^}]*\}\s*from\s*['`"][^'`"]+['`"];?", "")
    $content = [regex]::Replace($content, "(?s)import\s+.*?from\s*['`"][^'`"]+['`"];?", "")
    $content = [regex]::Replace($content, "(?m)^\s*import\s+.*?;?\s*$", "")
    # Remove export statements
    $content = [regex]::Replace($content, "(?m)^\s*export\s+default\s+", "")
    $content = [regex]::Replace($content, "(?m)^\s*export\s+", "")
    
    $fileName = [System.IO.Path]::GetFileName($f).ToUpper()
    $title = "$fileName MODULE"
    
    $bundle += "  // ═══════════════════════════════════════
"
    $bundle += "  // $idx. $title
"
    $bundle += "  // ═══════════════════════════════════════

"
    $bundle += $content.Trim() + "

"
    $idx++
}

$bootstrap = @"
  // ═══════════════════════════════════════
  // APP BOOTSTRAP
  // ═══════════════════════════════════════
  function withShell(pageName, renderContent) {
    return (container) => {
      container.innerHTML = renderAppShell(pageName);
      bindLogout();
      const content = document.getElementById('page-content');
      if (content) renderContent(content);
      if (typeof initCommandPalette === 'function') initCommandPalette();
      
      // Global ESC listener for standard modals
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
          const modals = document.querySelectorAll('.modal-backdrop:not(.hidden)');
          modals.forEach(m => m.classList.add('hidden'));
        }
      });
      
      initLucide();
    };
  }

  // Register public routes
  registerRoute('login',       (c) => { renderLogin(c); initLucide(); });
  registerRoute('staff-login', (c) => { renderLogin(c, 'staff'); initLucide(); });
  registerRoute('register',    (c) => { renderRegister(c); initLucide(); });
  registerRoute('verify-email',(c) => { renderVerifyEmail(c); initLucide(); });

  // Register protected routes
  registerRoute('dashboard',       withShell('dashboard',       renderDashboard));
  registerRoute('staff-dashboard', withShell('staff-dashboard', renderStaffDashboard));
  registerRoute('product-performance', withShell('product-performance', renderProductPerformance));
  registerRoute('billing',         withShell('billing',         renderBilling));
  registerRoute('sales',           withShell('sales',           renderSales));
  registerRoute('stock',           withShell('stock',           renderStock));
  registerRoute('new-stock',       (c) => { navigate('products?action=new-stock'); });
  registerRoute('products',        withShell('products',        renderProducts));
  registerRoute('customers',       withShell('customers',       renderCustomers));
  registerRoute('staff',           withShell('staff',           renderStaff));
  registerRoute('machines',        withShell('machines',        renderMachines));
  registerRoute('bill-customizer', withShell('bill-customizer', renderBillCustomizer));
  registerRoute('reports',         withShell('reports',         renderReports));
  registerRoute('settings',        withShell('settings',        renderSettings));
  registerRoute('account',         withShell('account',         renderAccount));
  registerRoute('communication',   withShell('communication',   renderCommunication));

  // Route change callback: update sidebar active state
  setRouteChangeCallback((page, role) => {
    document.querySelectorAll('.nav-item[data-page]').forEach(el => {
      el.classList.toggle('active', el.dataset.page === page);
    });
  });

  // Boot the router
  init();

})();
"@

$bundle += $bootstrap
$outputPath = "C:\Users\parth\.gemini\antigravity\scratch\shopflow\assets\js\bundle.js"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outputPath, $bundle, $utf8NoBom)
Write-Host "Bundle built without BOM! File size: $($bundle.Length) bytes."


