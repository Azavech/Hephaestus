# Original request

The request this documentation was written from, kept verbatim. The other files of `docs/` are the specification;
when they and this file differ, the other files win.

```text
create a new app compatible ios/macos/ipados. it will be written in swiftui and it's UI will adapt to the device (However since the mac will be the main computer to work ) . Project will be named : "Hephaestus"

This is app to coordinate work between all projects and no matter which device is used. 

only macs can be set as Main (where projects can live) all the devices (including macs) can be set as remotes.

main computers can exchange projects between them so if I have a project on my mac mini, I can migrate of of it to my macbook when I'm working remotely or put it back on the mini when I'm at home. 

all devices can get the status (online or not) of  the other devices. 

There should be a top ui to select (like xcode does) 
{ Main Device } >  { project }  > { sub project (if applicable) }

A project can have:

* Web Tabs (integrated web browser, some tabs can be locked to not be closed inadvertently) 
* Sub Projects (a sub project is a normal project inside a project)
* Tasks list  
* Code (code editor for go and swift should be included) with a file browser. 
* Documentation (Generally inside the code folder/docs) is many markdown files that can be edited and viewed


a project has a name and id (a project identifier is 2-8 letters that represent the project that is set by the user upon creation)
a task has a unique id (based on project identifier-numerical id)
a task has a name, a description, an id, a created date, a status (todo, in progress, review, done). it has a comment section with the ability to add files (that can be images but images should be viewed). it also has a claude section where I can open a tab that has access to everything about the ticket, either do implementation or debugging etc...

in each project I can have a claude chat to plan things, create multiple items etc, make him work on the app and do anything I want (create/update/run projects, create/update/delete tickets, comment on them run them etc...)

a project data will be set under .hephaestus/project.yml 
its tasks under .hephaestus/tasks/{taskid.yml}

any remote can see in real time the changes made anywhere. it should be as if the remote is the one working 

there should be a search feature so I can search pretty much anything

there will also be a feature to edit claude skills that can be used inside projects (it's an item I can create see and edit) they are in their own folders, not the ones in ~/.claude 

important: there will be an integration with claude cli. That's why only macs can only be set as main.


This app should be on github and auto built by a github pipeline where this prompt will be making a documentation pushed in the docs folder (the app must be built against the doc), it has a feedback feature that I can start pretty much anywhere in the app, a screenshot will be made and I can send a comment. then it will pop up a claude discussion that will update the doc accordingly and upon the doc being commited and pushed it will be regenerated then pushed and then github CI will rebuild it and the app will restart itself updated)
```
