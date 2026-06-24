// Inject a "← kipuka.dev" link at the top of the mdBook sidebar
(function() {
  var sidebar = document.querySelector('.sidebar-scrollbox');
  if (sidebar) {
    var link = document.createElement('a');
    link.href = '/';
    link.className = 'kipuka-home-link';
    link.textContent = 'kipuka.dev';
    sidebar.insertBefore(link, sidebar.firstChild);
  }
})();
