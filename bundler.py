import os
import re

bundle_path = r'C:\Users\parth\.gemini\antigravity\scratch\shopflow\assets\js\bundle.js'
base_dir = r'C:\Users\parth\.gemini\antigravity\scratch\shopflow\assets\js'

files = [
    'auth.js',
    'permissions.js',
    'router.js',
    'ui.js',
    'pages/login.js',
    'pages/register.js',
    'pages/dashboard.js',
    'pages/billing.js',
    'pages/sales.js',
    'pages/stock.js',
    'pages/new-stock.js',
    'pages/products.js',
    'pages/customers.js',
    'pages/staff.js',
    'pages/machines.js',
    'pages/bill-customizer.js',
    'pages/reports.js',
    'pages/settings.js',
    'pages/account.js'
]

def process_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # Remove import statements
    content = re.sub(r'^\s*import\s+.*?;?\s*$', '', content, flags=re.MULTILINE)
    
    # Remove 'export ' from export statements
    content = re.sub(r'^\s*export\s+default\s+', '', content, flags=re.MULTILINE)
    content = re.sub(r'^\s*export\s+', '', content, flags=re.MULTILINE)
    
    return content.strip() + '\n\n'

bundle_content = "(function() {\n  'use strict';\n\n"

for idx, file in enumerate(files):
    filepath = os.path.join(base_dir, file.replace('/', '\\'))
    title = f"{os.path.basename(file).upper()} MODULE"
    bundle_content += f"  // ═══════════════════════════════════════\n"
    bundle_content += f"  // {idx+1}. {title}\n"
    bundle_content += f"  // ═══════════════════════════════════════\n\n"
    bundle_content += process_file(filepath)

# Append App Bootstrap
bootstrap = """  // ═══════════════════════════════════════
  // APP BOOTSTRAP
  // ═══════════════════════════════════════
  function withShell(pageName, renderContent) {
    return (container) => {
      container.innerHTML = renderAppShell(pageName);
      bindLogout();
      const content = document.getElementById('page-content');
      if (content) renderContent(content);
      initLucide();
    };
  }

  // Register public routes
  registerRoute('login',       (c) => { renderLogin(c); initLucide(); });
  registerRoute('staff-login', (c) => { renderLogin(c, 'staff'); initLucide(); });
  registerRoute('register',    (c) => { renderRegister(c); initLucide(); });

  // Register protected routes
  registerRoute('dashboard',       withShell('dashboard',       renderDashboard));
  registerRoute('billing',         withShell('billing',         renderBilling));
  registerRoute('sales',           withShell('sales',           renderSales));
  registerRoute('stock',           withShell('stock',           renderStock));
  registerRoute('new-stock',       withShell('new-stock',       renderNewStock));
  registerRoute('products',        withShell('products',        renderProducts));
  registerRoute('customers',       withShell('customers',       renderCustomers));
  registerRoute('staff',           withShell('staff',           renderStaff));
  registerRoute('machines',        withShell('machines',        renderMachines));
  registerRoute('bill-customizer', withShell('bill-customizer', renderBillCustomizer));
  registerRoute('reports',         withShell('reports',         renderReports));
  registerRoute('settings',        withShell('settings',        renderSettings));
  registerRoute('account',         withShell('account',         renderAccount));

  // Route change callback: update sidebar active state
  setRouteChangeCallback((page, role) => {
    document.querySelectorAll('.nav-item[data-page]').forEach(el => {
      el.classList.toggle('active', el.dataset.page === page);
    });
  });

  // Boot the router
  init();

})();
"""
bundle_content += bootstrap

with open(bundle_path, 'w', encoding='utf-8') as f:
    f.write(bundle_content)
print("Bundle created successfully at:", bundle_path)
