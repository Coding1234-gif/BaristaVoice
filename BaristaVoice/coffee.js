let stock = {
    beans: 1000,     
    wholeMilk: 2000, 
    oatMilk: 2000
};

const max_stock = {
    beans: 1000,     
    wholeMilk: 2000, 
    oatMilk: 2000
};

const speech_btn = document.getElementById('order-btn');
const transcript = document.getElementById('transcript');

const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
let recognition;

if (SpeechRecognition) {
    recognition = new SpeechRecognition();
    recognition.continuous = false;
    recognition.lang = 'en-GB';
    recognition.interimResults = false;

    let orderProcessedForThisSession = false;

    recognition.onstart = () => {
        speech_btn.innerText = "🛑 Recording...";
        transcript.innerText = "Listening...";
        orderProcessedForThisSession = false;
    };

    recognition.onend = () => {
        speech_btn.innerText = "Click to Start";
    };

    recognition.onresult = (event) => {
        
        if (orderProcessedForThisSession) return;

        const spokenText = event.results[0][0].transcript.toLowerCase();
        
        if (event.results[0].isFinal || spokenText.includes('latte') || spokenText.includes('white') || spokenText.includes('cappuccino') || spokenText.includes('espresso') || spokenText.includes('americano')) {
            
            orderProcessedForThisSession = true;
            transcript.innerText = spokenText;
            processCoffeeOrder(spokenText);
            
            recognition.stop();
        }
    };


} else {
    alert("Speech recognition is not supported in this browser. Please use Chrome!");
}

speech_btn.addEventListener('click', () => {
    if (recognition) {
        recognition.start();
    }

    updateStockUI();
});

const drinkRecipes = {
    'latte': { beans: 18, milkVolume: 250 },
    'cappuccino': { beans: 18, milkVolume: 200 },
    'flat white': { beans: 18, milkVolume: 110 },
    'americano': { beans: 18, milkVolume: 0 },
    'espresso': { beans: 18, milkVolume: 0 }
};

function processCoffeeOrder(text) {
    let matchedDrink = null;

    const isOat = text.includes('oat');
    
    let cleanText = text.replace('oat', '').trim();

    if (cleanText.includes('flat white')) {
        matchedDrink = 'flat white';
    } else if (cleanText.includes('cappuccino')) {
        matchedDrink = 'cappuccino';
    } else if (cleanText.includes('espresso')) {
        matchedDrink = 'espresso';
    } else if (cleanText.includes('latte')) {
        matchedDrink = 'latte';
    } else if (cleanText.includes('americano')) {
        matchedDrink = 'americano';
    }

    if (!matchedDrink) {
        console.log("Could not find a drink match for:", text);
        return;
    }

    console.log("Success! Processing recipe data for:", matchedDrink);
    deductStock(matchedDrink, isOat);
}

function deductStock(baseDrink, isOat) {

    const baseRecipe = drinkRecipes[baseDrink];

    if (!baseRecipe) return;
    
    stock.beans = Math.max(0, stock.beans - baseRecipe.beans);
    
    if (baseRecipe.milkVolume > 0) {
        if (isOat) {
            stock.oatMilk = Math.max(0, stock.oatMilk - baseRecipe.milkVolume);
        } else {
            stock.wholeMilk = Math.max(0, stock.wholeMilk - baseRecipe.milkVolume);
        }
    }

    updateStockUI();
    
    addOrderToQueueUI(baseDrink, isOat);
}

function updateStockUI() {

    function calculatePercentage(current, max) {
        if (max === 0) return 0;
        return (current / max) * 100;
    }

    const beansPercentage = calculatePercentage(stock.beans, max_stock.beans);
    const milkPercentage = calculatePercentage(stock.wholeMilk, max_stock.wholeMilk);
    const oatMilkPercentage = calculatePercentage(stock.oatMilk, max_stock.oatMilk);

    document.getElementById('bar-beans').style.width = beansPercentage + '%';
    document.getElementById('bar-milk').style.width = milkPercentage + '%';
    document.getElementById('bar-oat-milk').style.width = oatMilkPercentage + '%';

    document.getElementById('beans-stock').innerText = `${stock.beans}g of coffee beans remaining`;
    document.getElementById('milk-stock').innerText = `${stock.wholeMilk}ml of whole milk remaining`;
    document.getElementById('oat-milk-stock').innerText = `${stock.oatMilk}ml of oat milk remaining`;

    
}

function addOrderToQueueUI(baseDrink, isOat) {
    const queueContainer = document.getElementById('order-queue');
    
    const ticketCard = document.createElement('div');
    const ticketId = 'ticket-' + Date.now();
    ticketCard.id = ticketId;
    ticketCard.className = "ticketCard";
    
    const displayLabel = isOat ? `📢 Oat ${baseDrink}` : `☕ Standard ${baseDrink}`;
    
    ticketCard.innerHTML = `
        <span>${displayLabel}</span>
        <button id="complete-btn" onclick="removeOrderFromQueue('${ticketId}')">
            Complete ✓
        </button>
    `;
    
    queueContainer.appendChild(ticketCard);
}

function removeOrderFromQueue(id) {
    const ticket = document.getElementById(id);

    if (ticket) {
        ticket.remove();
    }
}

