fetch('https://api.github.com/repos/ohmyangboy/PaperRss')
  .then(r => console.log(r.status, r.ok))
  .catch(e => console.error(e));
