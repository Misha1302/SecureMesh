'use strict';

const copyButton = document.querySelector('#copy-address');
const address = document.querySelector('#server-address');
const copyStatus = document.querySelector('#copy-status');
const offlineStatus = document.querySelector('#offline-status');
const standalone = window.matchMedia('(display-mode: standalone)');

const installButton = document.querySelector('#install-app');
const installResult = document.querySelector('#install-result');
let installPrompt;
let installAccepted = false;

function updateInstallInstructions() {
  const separateWindow = standalone.matches || navigator.standalone === true;
  document.querySelector('#standalone').hidden = !separateWindow;
  document.querySelector('#install-guide').hidden = separateWindow || installAccepted;
  installButton.hidden = separateWindow || installAccepted || !installPrompt;
}

window.addEventListener('beforeinstallprompt', event => {
  event.preventDefault();
  installPrompt = event;
  updateInstallInstructions();
});
installButton.addEventListener('click', async () => {
  const prompt = installPrompt;
  if (!prompt) return;
  installPrompt = undefined;
  installResult.textContent = '';
  updateInstallInstructions();
  try {
    await prompt.prompt();
    await prompt.userChoice;
  } catch {
    if (!installAccepted) installResult.textContent = 'Откройте инструкцию для своего устройства ниже.';
  }
});
window.addEventListener('appinstalled', () => {
  installAccepted = true;
  installPrompt = undefined;
  installResult.textContent = 'Браузер принял установку SecureMesh.';
  updateInstallInstructions();
});
standalone.addEventListener?.('change', updateInstallInstructions);
updateInstallInstructions();

copyButton.hidden = false;
copyButton.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(address.value);
    copyStatus.textContent = 'Адрес скопирован.';
  } catch {
    address.focus();
    address.select();
    address.setSelectionRange(0, address.value.length);
    copyStatus.textContent = 'Адрес выделен. Нажмите «Скопировать» в меню выделения.';
  }
});

function showOfflineStatus(text, ready = false) {
  offlineStatus.textContent = text;
  offlineStatus.toggleAttribute('data-ready', ready);
}

async function activateOfflineGuide() {
  if (!('serviceWorker' in navigator)) {
    showOfflineStatus('Для сохранения справки откройте HTTPS-страницу в браузере.');
    return;
  }

  const retry = 'Офлайн-справка ещё не сохранена. Обновите страницу при подключении к интернету.';
  try {
    showOfflineStatus('Подготовка справки к работе офлайн…');
    const registration = await navigator.serviceWorker.register('./sw.js', { scope: './' });
    const script = new URL('./sw.js', registration.scope).href;
    const isControlled = () => navigator.serviceWorker.controller?.scriptURL === script;
    const status = () => {
      if (isControlled()) {
        showOfflineStatus('Справка доступна офлайн', true);
      }
    };

    navigator.serviceWorker.addEventListener('controllerchange', status);
    status();

    const watchInstallation = () => {
      const worker = registration.installing;
      if (!worker) return;
      const checkState = () => {
        if (worker.state === 'redundant' && !isControlled()) showOfflineStatus(retry);
      };
      worker.addEventListener('statechange', checkState);
      checkState();
    };

    watchInstallation();
    registration.addEventListener('updatefound', watchInstallation);
  } catch {
    showOfflineStatus(retry);
  }
}

activateOfflineGuide();
