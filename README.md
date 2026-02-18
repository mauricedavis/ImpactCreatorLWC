# Impact Creator LWC

A Lightning Web Component for creating Impacts (Opportunities) from Cases in Salesforce. Built for Michigan SBDC/GVSU to replace the legacy screen flow "New_Impact_Create_Impact_from_Case".

## Features

- **4-Step Wizard Interface**: Guided process for creating Impacts with validation at each step
- **Impact Details**: Capture key information including attribution date, stage, sales metrics, and job counts
- **Capital Sources**: Select and configure multiple capital sources (Products) with amounts, dates, types, and partner organizations
- **Team Members**: Add team members with role assignments and automatic value distribution
- **Quick Action Support**: Launch as a modal from the Case record page via a "New Impact" button
- **Responsive Design**: Optimized layout for both full-page and modal views
- **Auto PricebookEntry Creation**: Automatically creates missing Standard Pricebook entries for products

## Project Structure

```
force-app/main/default/
├── classes/
│   ├── ImpactCreatorController.cls          # Apex controller
│   ├── ImpactCreatorController.cls-meta.xml
│   ├── ImpactCreatorControllerTest.cls      # Test class (90%+ coverage)
│   └── ImpactCreatorControllerTest.cls-meta.xml
├── lwc/
│   └── impactCreator/
│       ├── impactCreator.html               # Component template
│       ├── impactCreator.js                 # Component controller
│       ├── impactCreator.css                # Component styles
│       └── impactCreator.js-meta.xml        # Component configuration
└── quickActions/
    └── Case.New_Impact.quickAction-meta.xml # Quick Action definition
```

## Installation

### Prerequisites

- Salesforce CLI (`sf`) installed
- Authenticated to your Salesforce org

### Deploy to Org

```bash
# Deploy all components
sf project deploy start --source-dir force-app/main/default --target-org YOUR_ORG_ALIAS

# Or deploy specific components
sf project deploy start \
  --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/lwc/impactCreator \
  --target-org YOUR_ORG_ALIAS
```

## Configuration

### Option 1: Add to Case Record Page (Embedded)

1. Go to **Setup** → **Object Manager** → **Case** → **Lightning Record Pages**
2. Edit your Case record page in Lightning App Builder
3. Drag the **Impact Creator** component onto the page
4. Save and activate

### Option 2: Add as Quick Action (Modal)

1. Go to **Setup** → **Object Manager** → **Case** → **Buttons, Links, and Actions**
2. Click **New Action**
3. Configure:
   - **Action Type**: Lightning Web Component
   - **Lightning Web Component**: `c:impactCreator`
   - **Label**: `New Impact`
   - **Name**: `New_Impact`
4. Save
5. Add the action to your Case page layout or Lightning Record Page highlights panel

## Custom Fields Required

### Opportunity (Impact)
- `Case__c` - Lookup to Case
- `Sales_Increase__c` - Currency
- `Sales_Source__c` - Picklist
- `Jobs_Created__c` - Number
- `Jobs_Retained__c` - Number
- `New_Business__c` - Checkbox
- `Bought_Business__c` - Checkbox
- `Sold_Business__c` - Checkbox
- `Business_Start_Date__c` - Date

### OpportunityLineItem
- `Capital_Source_Type__c` - Picklist
- `Capital_Source__c` - Lookup to Account

### OpportunityTeamMember
- `Capital_Formation__c` - Currency
- `Jobs_Created__c` - Number
- `Jobs_Retained__c` - Number
- `Sales_Increase__c` - Currency
- `Impact_Attribution_Year__c` - Text

### Account
- `Start_Date__c` - Date
- `In_Business__c` - Checkbox

### Product2
- `Sub_Type__c` - Picklist
- `Partner_Type__c` - Picklist

## Usage

1. Navigate to a Case record
2. Click the **New Impact** button (or scroll to the embedded component)
3. **Step 1 - Impact Details**: Enter impact name, attribution date, stage, and metrics
4. **Step 2 - Capital Sources**: Select products from the list, configure amounts and partners
5. **Step 3 - Impact Team**: Add team members, assign roles, distribute values
6. **Step 4 - Review & Create**: Review all information and create the Impact

## Development

### Run Tests

```bash
# Run Apex tests
sf apex run test --class-names ImpactCreatorControllerTest --result-format human --target-org YOUR_ORG_ALIAS

# Run Jest tests (LWC)
npm run test
```

### Linting

```bash
npm run lint
```

## License

This project is proprietary software developed for Michigan SBDC/GVSU.

## Author

Michigan SBDC Development Team
