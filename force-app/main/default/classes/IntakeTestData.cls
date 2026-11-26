@IsTest
public class IntakeTestData {

    public static String resumeJson(String name, String email, String phone) {
        Map<String, Object> acc = new Map<String, Object>{
            'name' => name, 'email' => email, 'phone' => phone,
            'dateofBirth' => '15/05/1995', 'currentLocation' => 'Chennai',
            'currentCompany' => 'Acme Pvt Ltd', 'pastCompanies' => new List<Object>{ 'Wipro (2019-06 to 2022-08) Developer' },
            'languagesKnown' => 'English, Tamil', 'summary' => 'Salesforce developer with 5 years of experience.',
            'experience' => '5.5 years', 'linkedin' => 'https://www.linkedin.com/in/test-' + (email == null ? 'x' : email.substringBefore('@')),
            'filename' => 'ignored', 'degree' => 'B.E', 'college' => 'Anna University', 'designation' => 'Senior Developer'
        };
        Map<String, Object> resume = new Map<String, Object>{
            'account' => acc,
            'skills' => new List<Object>{
                new Map<String, Object>{ 'name' => 'Apex', 'proficiency' => 'Expert', 'Category' => 'Technical' },
                new Map<String, Object>{ 'name' => 'LWC', 'proficiency' => 'weird', 'Category' => 'Technical' }
            },
            'certifications' => new List<Object>{
                new Map<String, Object>{ 'name' => 'Platform Developer I', 'issuedBy' => 'Salesforce', 'issueDate' => '2021-03-01', 'expiryDate' => '' }
            },
            'projects' => new List<Object>{
                new Map<String, Object>{ 'projectName' => 'CPQ Rollout', 'clientName' => 'Acme', 'projectRole' => 'Developer',
                    'startDate' => 'Jan-2022', 'endDate' => 'Present', 'toolsUsed' => 'VS Code' }
            }
        };
        return JSON.serialize(new Map<String, Object>{ 'documentType' => 'Resume', 'resumes' => new List<Object>{ resume } });
    }

    public static String jdJson(String company, String role, String docType) {
        Map<String, Object> jd = new Map<String, Object>{
            'title' => role, 'ar' => '2', 'companyName' => company, 'experience' => '3-5',
            'tagline' => 'Join us', 'responsibilities' => 'Design and build Salesforce Apex triggers, Lightning components and integrations for the sales cloud implementation',
            'otherLocation' => 'Remote', 'preferredLocation' => 'Chennai', 'qualifications' => 'B.E with 3-5 years',
            'seniority' => 'Senior', 'skillsRequired' => 'Apex, LWC, Integration', 'duration' => '6 months',
            'opportunityName' => role, 'opportunityCloseDate' => '15-01-2030', 'opportunityStartDate' => '',
            'opportunityAmount' => '18', 'referralContact' => '', 'jobType' => 'remote',
            'budgetMentioned' => '1500', 'currencyMentioned' => 'OMR'
        };
        return JSON.serialize(new Map<String, Object>{
            'documentType' => docType,
            'jobs' => new List<Object>{ new Map<String, Object>{ 'jobDescription' => jd } }
        });
    }

    public static Id newIntake(String requestedType, String fileName, String body) {
        Service__c s = new Service__c(Name = fileName, Source_Channel__c = 'UI Upload',
            Requested_Type__c = requestedType, Status__c = 'Queued', Request_Key__c = 'k-' + Crypto.getRandomInteger());
        insert s;
        ContentVersion cv = new ContentVersion(Title = fileName, PathOnClient = fileName,
            VersionData = Blob.valueOf(body), FirstPublishLocationId = s.Id);
        insert cv;
        s.File_Checksum__c = [SELECT Checksum FROM ContentVersion WHERE Id = :cv.Id].Checksum;
        update s;
        return s.Id;
    }
}